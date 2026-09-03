# frozen_string_literal: true

require "json"
require "shellwords"

module Lemans
  module Agents
    module Harnesses
      # Claude Code in headless mode. No ~/.claude exists in the image and
      # --setting-sources project excludes user scope, so only the repository's
      # own CLAUDE.md, settings and skills load.
      class ClaudeCode < Harness
        NAME = "claude-code"
        VERSION = "2.1.259"

        OUTCOME_FOR_SUBTYPE = {
          "success" => :completed,
          "error_max_turns" => :step_limit_reached,
          "error_max_budget_usd" => :cost_ceiling_reached
        }.freeze

        def initialize(profile:, model: nil)
          super
          raise ConfigError, "claude-code needs ANTHROPIC_API_KEY in the environment" if ENV["ANTHROPIC_API_KEY"].to_s.empty?
        end

        def install_command
          "command -v claude >/dev/null 2>&1 || npm install -g --no-fund --no-audit @anthropic-ai/claude-code@#{VERSION}"
        end

        def command
          argv = [ "claude", "-p", "--output-format", "stream-json", "--verbose",
                   "--model", model_name, "--permission-mode", "bypassPermissions",
                   "--setting-sources", "project", "--strict-mcp-config", "--no-session-persistence",
                   "--max-turns", profile.step_limit ]
          argv += [ "--max-budget-usd", profile.cost_limit ] if profile.cost_limit
          argv.map { Shellwords.escape(it.to_s) }.join(" ")
        end

        # Sandboxes run as root, which Claude Code refuses for bypassPermissions unless IS_SANDBOX is set.
        def env
          { "ANTHROPIC_API_KEY" => ENV.fetch("ANTHROPIC_API_KEY"),
            "IS_SANDBOX" => "1",
            "DISABLE_AUTOUPDATER" => "1",
            "DISABLE_TELEMETRY" => "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1" }
        end

        def parse(output, exit_code)
          events = events_in(output)
          trajectory = Trajectory.new(events, model:, agent: { name:, version: VERSION })
          result = events.find { it["type"] == "result" }
          unless result
            return Response.new(error: "no result event in the stream (exit #{exit_code})",
                                usage: salvaged_usage(events), trajectory:, raw_result: output)
          end

          usage = usage_for(result, events)
          status = OUTCOME_FOR_SUBTYPE[result["subtype"]]
          # A dead key surfaces as subtype success with is_error set, so the flag decides.
          if status.nil? || (status == :completed && result["is_error"])
            return Response.new(error: "#{result["subtype"]}: #{result["result"].to_s[0, 500]}",
                                usage:, trajectory:, raw_result: output)
          end

          Response.new(outcome: Result::Outcome.new(status, detail_for(result)), usage:, trajectory:, raw_result: output)
        end

        private

        def events_in(output)
          output.each_line.filter_map do |line|
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end

        def detail_for(result)
          case result["subtype"]
          when "error_max_turns" then "hit --max-turns #{profile.step_limit}"
          when "error_max_budget_usd" then "hit --max-budget-usd #{profile.cost_limit}"
          end
        end

        def usage_for(result, events)
          usage = result.fetch("usage", {})
          cost = result["total_cost_usd"]
          steps = result["num_turns"].to_i
          return salvaged_usage(events, steps:) unless cost.is_a?(Numeric)

          Result::Usage.new(
            input_tokens: usage["input_tokens"].to_i,
            output_tokens: usage["output_tokens"].to_i,
            cached_tokens: usage["cache_read_input_tokens"].to_i + usage["cache_creation_input_tokens"].to_i,
            steps:,
            cost_usd: cost.to_f,
            cost_source: Result::CostSource.new(name: :harness, model:, priced_as: "claude-code total_cost_usd", registry: nil)
          )
        end

        # A stream with no priced result (killed, or an older CLI) still carries per-message usage.
        def salvaged_usage(events, steps: nil)
          messages = events.select { it["type"] == "assistant" }.uniq { it.dig("message", "id") }
          return Result::Usage.zero if messages.empty?

          usages = messages.map { it.dig("message", "usage") || {} }
          priced(
            input_tokens: usages.sum { it["input_tokens"].to_i },
            output_tokens: usages.sum { it["output_tokens"].to_i },
            cache_read_tokens: usages.sum { it["cache_read_input_tokens"].to_i },
            cache_write_tokens: usages.sum { it["cache_creation_input_tokens"].to_i },
            steps: steps || messages.size
          )
        end
      end
    end
  end
end
