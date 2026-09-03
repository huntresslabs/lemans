# frozen_string_literal: true

require "test_helper"

class HarnessAdapterTest < Minitest::Test
  include BenchFixture

  # A harness that echoes whatever the sandbox returned, so the shared loop can be tested alone.
  class EchoHarness < Lemans::Agents::Harness
    NAME = "echo"

    def command = "echo-agent --go"

    def env = { "ECHO_TOKEN" => "t" }

    def parse(output, exit_code)
      return Lemans::Agent::Response.new(error: "garbage (exit #{exit_code})", raw_result: output) if output.include?("garbage")

      Lemans::Agent::Response.new(outcome: Lemans::Result::Outcome.new(:completed), usage: Lemans::Result::Usage.zero, raw_result: output)
    end
  end

  # A sandbox whose harness invocation exits with a scripted code and leaves scripted files behind.
  class ScriptedEnvironment < TestEnvironment
    attr_reader :envs

    def initialize(exit_code:, **)
      super(**)
      @exit_code = exit_code
      @envs = []
    end

    def exec(command, timeout: nil, env: {})
      @envs << env
      return super unless command.include?("echo-agent")

      @commands << command
      Lemans::Environment::ExecResult.new(command:, exit_code: @exit_code, output: "", duration: 1.0)
    end
  end

  def setup
    @config = load_config
    @task = load_task(@config)
    @profile = @config.agent
    @profile.timeout = 90
  end

  def test_the_loop_uploads_the_prompt_runs_the_command_in_the_workdir_and_cleans_up
    environment = ScriptedEnvironment.new(exit_code: 0, files: { "/tmp/lemans-harness.out" => "ok", "/tmp/lemans-harness.err" => "" })
    response = EchoHarness.new(profile: @profile, model: "anthropic/x").run(@task, environment)

    assert_equal [ "/tmp/lemans-prompt.md" ], environment.uploads.map(&:last)
    run = environment.commands.find { it.include?("echo-agent") }
    assert_equal "cd /app && echo-agent --go < /tmp/lemans-prompt.md > /tmp/lemans-harness.out 2> /tmp/lemans-harness.err", run
    assert_includes environment.envs, { "ECHO_TOKEN" => "t" }
    assert_includes environment.commands, "rm -f /tmp/lemans-prompt.md /tmp/lemans-harness.out /tmp/lemans-harness.err"
    assert_predicate response.outcome, :completed?
    assert_equal "ok", response.raw_result
  end

  def test_exit_124_is_an_agent_timeout_with_whatever_usage_was_salvaged
    environment = ScriptedEnvironment.new(exit_code: 124, files: { "/tmp/lemans-harness.out" => "partial", "/tmp/lemans-harness.err" => "" })
    response = EchoHarness.new(profile: @profile, model: "anthropic/x").run(@task, environment)

    assert_predicate response.outcome, :agent_timeout?
    assert_equal "the CLI was killed after 90s", response.outcome.detail
    assert_equal Lemans::Result::Usage.zero, response.usage
    refute_predicate response, :error?
  end

  def test_unparseable_output_is_an_agent_error_carrying_stderr
    environment = ScriptedEnvironment.new(exit_code: 1, files: { "/tmp/lemans-harness.out" => "garbage", "/tmp/lemans-harness.err" => "boom: no such tool" })
    response = EchoHarness.new(profile: @profile, model: "anthropic/x").run(@task, environment)

    assert_predicate response, :error?
    assert_equal "echo: garbage (exit 1): boom: no such tool", response.error
  end

  def test_install_is_skipped_without_an_install_command
    environment = ScriptedEnvironment.new(exit_code: 0)
    EchoHarness.new(profile: @profile, model: "anthropic/x").install(@task, environment)

    assert_empty environment.commands
  end

  def test_model_strings_split_into_provider_and_name
    harness = EchoHarness.new(profile: @profile, model: "anthropic/claude-fable-5-1")

    assert_equal "anthropic", harness.send(:provider)
    assert_equal "claude-fable-5-1", harness.send(:model_name)
    assert_nil EchoHarness.new(profile: @profile, model: "claude-fable-5-1").send(:provider)
  end
end
