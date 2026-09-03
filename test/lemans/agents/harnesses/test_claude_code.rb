# frozen_string_literal: true

require "test_helper"

class ClaudeCodeAdapterTest < Minitest::Test
  include BenchFixture

  FIXTURES = Pathname(File.expand_path("../../../fixtures/harnesses/claude_code", __dir__))

  def setup
    ENV["ANTHROPIC_API_KEY"] = "test-key"
    @config = load_config
    @profile = @config.agent
    @profile.step_limit = 40
    @profile.cost_limit = 2.5
    @adapter = Lemans::Agents::Harnesses::ClaudeCode.new(profile: @profile, model: "anthropic/claude-haiku-4-5-20251001")
  end

  def teardown = ENV.delete("ANTHROPIC_API_KEY")

  def test_registered_by_name
    agent = Lemans::Agents.build("claude-code", profile: @profile, model: "anthropic/claude-fable-5-1")

    assert_instance_of Lemans::Agents::Harnesses::ClaudeCode, agent
    assert_equal "claude-code", agent.name
  end

  def test_a_missing_key_is_a_config_error_before_any_sandbox_exists
    ENV.delete("ANTHROPIC_API_KEY")

    error = assert_raises(Lemans::ConfigError) { Lemans::Agents::Harnesses::ClaudeCode.new(profile: @profile, model: "anthropic/x") }
    assert_equal "claude-code needs ANTHROPIC_API_KEY in the environment", error.message
  end

  def test_the_command_pins_the_model_budgets_and_isolation_flags
    command = @adapter.command

    assert_equal "claude -p --output-format stream-json --verbose --model claude-haiku-4-5-20251001 " \
                 "--permission-mode bypassPermissions --setting-sources project --strict-mcp-config " \
                 "--no-session-persistence --max-turns 40 --max-budget-usd 2.5", command
    assert_includes @adapter.install_command, "@anthropic-ai/claude-code@#{Lemans::Agents::Harnesses::ClaudeCode::VERSION}"
    assert_equal "test-key", @adapter.env.fetch("ANTHROPIC_API_KEY")
    assert_equal "1", @adapter.env.fetch("DISABLE_AUTOUPDATER")
    assert_equal "1", @adapter.env.fetch("IS_SANDBOX")
  end

  def test_a_success_result_is_completed_with_the_harness_reported_cost
    response = @adapter.parse(fixture("success"), 0)

    assert_predicate response.outcome, :completed?
    assert_in_delta 0.0109506, response.usage.cost_usd
    assert_equal 10, response.usage.input_tokens
    assert_equal 41, response.usage.output_tokens
    assert_equal 6740 + 13716, response.usage.cached_tokens
    assert_equal 1, response.usage.steps
    assert_equal :harness, response.usage.cost_source.name
    refute_predicate response, :error?
  end

  def test_max_turns_and_budget_map_to_their_scored_outcomes
    turns = @adapter.parse(fixture("max_turns"), 1)
    budget = @adapter.parse(fixture("budget"), 1)

    assert_predicate turns.outcome, :step_limit_reached?
    assert_equal "hit --max-turns 40", turns.outcome.detail
    assert_equal 2, turns.usage.steps
    assert_predicate budget.outcome, :cost_ceiling_reached?
    assert_equal "hit --max-budget-usd 2.5", budget.outcome.detail
    assert_in_delta 0.000967, budget.usage.cost_usd
  end

  def test_errors_are_agent_errors_not_zeros_whatever_the_subtype_says
    unknown = @adapter.parse(fixture("success").sub('"subtype":"success"', '"subtype":"error_during_execution"'), 1)
    auth = @adapter.parse(fixture("auth_error"), 0)

    assert_predicate unknown, :error?
    assert_includes unknown.error, "error_during_execution"
    assert_predicate auth, :error?
    assert_includes auth.error, "401 API key is invalid"
    assert_equal 0.0, auth.usage.cost_usd
  end

  def test_a_stream_without_a_result_is_an_error_whose_usage_is_priced_from_the_registry
    stream = fixture("max_turns").lines.reject { it.include?('"type":"result"') }.join
    response = @adapter.parse(stream, 137)

    assert_predicate response, :error?
    assert_equal "no result event in the stream (exit 137)", response.error
    assert_equal :model_registry, response.usage.cost_source.name
    assert_operator response.usage.cost_usd, :>, 0
    assert_equal 1, response.usage.steps
  end

  def test_a_model_with_no_published_price_is_refused_not_free
    adapter = Lemans::Agents::Harnesses::ClaudeCode.new(profile: @profile, model: "selfhosted/some-unpriced-model")
    stream = fixture("max_turns").lines.reject { it.include?('"type":"result"') }.join

    assert_raises(Miniswen::AccountingError) { adapter.parse(stream, 137) }
  end

  def test_the_trajectory_is_valid_atif_with_linked_tool_results
    response = @adapter.parse(fixture("max_turns"), 1)
    atif = response.trajectory.to_atif

    assert_empty ATIFSchema.errors(atif)
    agent_steps = atif[:steps].select { it[:source] == "agent" }
    call = agent_steps.flat_map { it[:tool_calls] || [] }.first
    observation = agent_steps.flat_map { it.dig(:observation, :results) || [] }.first
    assert_equal "Write", call[:function_name]
    assert_equal call[:tool_call_id], observation[:source_call_id]
    assert_equal "system", atif[:steps].first[:source]
    assert_equal 2, atif[:final_metrics][:total_steps]
    assert_equal "claude-code", atif[:agent][:name]
  end

  private

  def fixture(name) = FIXTURES.join("#{name}.jsonl").read
end
