# frozen_string_literal: true

require "json"

module Lemans
  module Agents
    module Harnesses
      # A Claude Code stream-json run as an ATIF-v1.7 document: one step per
      # system or assistant message, tool results folded onto the step that
      # called them.
      class Trajectory
        SCHEMA_VERSION = "ATIF-v1.7"

        attr_writer :session_id

        def initialize(events, model:, agent:, session_id: nil)
          @events = events
          @model = model
          @agent = agent
          @session_id = session_id
        end

        def to_atif
          {
            schema_version: SCHEMA_VERSION,
            session_id: session_id || result&.dig("session_id"),
            agent: agent.merge(model_name: model.to_s),
            steps:,
            final_metrics:
          }.compact
        end

        private

        attr_reader :events, :model, :agent, :session_id

        def result = events.find { it["type"] == "result" }

        def steps
          events.each_with_object([]) do |event, acc|
            case event["type"]
            when "system" then acc << system_step(event, acc.size + 1) if event["subtype"] == "init"
            when "assistant" then merge_assistant(acc, event)
            when "user" then fold_results(acc, event)
            end
          end
        end

        def system_step(event, step_id)
          summary = event.slice("model", "permissionMode", "cwd", "claude_code_version").compact
          summary["tools"] = Array(event["tools"]).size if event.key?("tools")
          { step_id:, source: "system", message: "init #{JSON.generate(summary)}" }
        end

        # One API message arrives as several events, one per content block.
        def merge_assistant(acc, event)
          message = event.fetch("message", {})
          step = acc.last if acc.last && acc.last[:extra]&.dig(:message_id) == message["id"]
          unless step
            step = { step_id: acc.size + 1, source: "agent", message: "", model_name: message["model"] || model.to_s,
                     extra: { message_id: message["id"] }.compact }
            step[:metrics] = metrics_for(message["usage"]) if message["usage"]
            acc << step
          end

          Array(message["content"]).each do |block|
            case block["type"]
            when "text" then step[:message] = [ step[:message], block["text"] ].reject(&:empty?).join("\n")
            when "thinking" then step[:reasoning_content] = [ step[:reasoning_content], block["thinking"] ].compact.join("\n")
            when "tool_use"
              (step[:tool_calls] ||= []) << { tool_call_id: block["id"], function_name: block["name"], arguments: block["input"] || {} }
            end
          end
        end

        def fold_results(acc, event)
          step = acc.reverse.find { it[:source] == "agent" } or return
          Array(event.dig("message", "content")).each do |block|
            next unless block["type"] == "tool_result"

            (step[:observation] ||= { results: [] })[:results] << {
              source_call_id: block["tool_use_id"],
              content: block["content"].is_a?(String) ? block["content"] : JSON.generate(block["content"])
            }
          end
        end

        def metrics_for(usage)
          {
            prompt_tokens: usage["input_tokens"].to_i,
            completion_tokens: usage["output_tokens"].to_i,
            cached_tokens: usage["cache_read_input_tokens"].to_i + usage["cache_creation_input_tokens"].to_i
          }
        end

        def final_metrics
          return unless result

          usage = result.fetch("usage", {})
          {
            total_prompt_tokens: usage["input_tokens"].to_i,
            total_completion_tokens: usage["output_tokens"].to_i,
            total_cached_tokens: usage["cache_read_input_tokens"].to_i + usage["cache_creation_input_tokens"].to_i,
            total_cost_usd: result["total_cost_usd"],
            total_steps: result["num_turns"].to_i
          }.compact
        end
      end
    end
  end
end
