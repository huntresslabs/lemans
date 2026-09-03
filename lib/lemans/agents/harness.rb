# frozen_string_literal: true

require "shellwords"
require "tempfile"

module Lemans
  module Agents
    # A coding-agent CLI run inside the sandbox. An adapter names the install
    # command, the invocation that reads its prompt from stdin, the environment
    # it needs, and how its output becomes a Response; the loop lives here.
    class Harness < Agent
      PROMPT_PATH = "/tmp/lemans-prompt.md"
      OUTPUT_PATH = "/tmp/lemans-harness.out"
      STDERR_PATH = "/tmp/lemans-harness.err"
      INSTALL_TIMEOUT = 600

      def install(_task, environment)
        environment.exec!(install_command, timeout: INSTALL_TIMEOUT) if install_command
      end

      def run(task, environment)
        upload_prompt(task, environment)
        run = environment.exec(shell_command(task), timeout: profile.timeout, env:)
        output = download(environment, OUTPUT_PATH)
        stderr = download(environment, STDERR_PATH)
        environment.exec("rm -f #{PROMPT_PATH} #{OUTPUT_PATH} #{STDERR_PATH}")

        response = parse(output, run.exit_code)
        return timed_out(response) if run.exit_code == 124
        return response unless response.error?

        response.with(error: "#{name}: #{response.error}#{excerpt(stderr)}")
      end

      def install_command = nil

      def command
        raise NotImplementedError
      end

      def env = {}

      def parse(_output, _exit_code)
        raise NotImplementedError
      end

      private

      # Model strings carry a provider prefix (provider/model-id).
      def provider = model.to_s.include?("/") ? model.to_s.split("/", 2).first : nil

      def model_name = model.to_s.split("/", 2).last

      def upload_prompt(task, environment)
        Tempfile.create(%w[lemans-prompt .md]) do |file|
          file.write(task.instruction)
          file.flush
          environment.upload(file.path, PROMPT_PATH)
        end
      end

      def shell_command(task)
        "cd #{Shellwords.escape(task.environment.workdir)} && #{command} < #{PROMPT_PATH} > #{OUTPUT_PATH} 2> #{STDERR_PATH}"
      end

      def download(environment, remote)
        Tempfile.create("lemans-harness") do |file|
          environment.download(remote, file.path)
          File.read(file.path)
        end
      rescue StandardError
        ""
      end

      def timed_out(response)
        Response.new(
          outcome: Result::Outcome.new(:agent_timeout, "the CLI was killed after #{profile.timeout.to_i}s"),
          usage: response.usage || Result::Usage.zero,
          trajectory: response.trajectory,
          raw_result: response.raw_result
        )
      end

      def excerpt(stderr)
        text = stderr.to_s.strip
        text.empty? ? "" : ": #{text[-1500..] || text}"
      end

      # Prices tokens through the RubyLLM registry when the harness reports no cost.
      def priced(input_tokens:, output_tokens:, cache_read_tokens:, cache_write_tokens:, steps:)
        info = registry_info
        input, output = info && [ info.input_price_per_million, info.output_price_per_million ]
        unless input.is_a?(Numeric) && output.is_a?(Numeric)
          raise ::Miniswen::AccountingError,
                "#{model.inspect} has no published price, so #{input_tokens} input and " \
                "#{output_tokens} output tokens cannot be reported as $0.00"
        end

        cost = ((input_tokens * input) +
                (cache_read_tokens * (info.cache_read_input_price_per_million || input)) +
                (cache_write_tokens * (info.cache_write_input_price_per_million || input)) +
                (output_tokens * output)) / 1_000_000.0
        Result::Usage.new(
          input_tokens:, output_tokens:, cached_tokens: cache_read_tokens + cache_write_tokens, steps:,
          cost_usd: cost,
          cost_source: Result::CostSource.new(name: :model_registry, model:, priced_as: "#{info.provider}/#{info.id}",
                                              registry: ::Miniswen.registry_revision)
        )
      end

      def registry_info
        provider ? RubyLLM.models.find(model_name, provider) : RubyLLM.models.find(model_name)
      rescue RubyLLM::ModelNotFoundError
        nil
      end
    end
  end
end
