require_relative "test_helper"
require "dev_boxer/ai_reply"

class AiReplyTest < Minitest::Test
  def test_only_successful_assistant_results_count_as_a_reply
    assert DevBoxer::AiReply.ready?("claude", JSON.generate(type: "result", is_error: false, result: "Matron is ready"))
    refute DevBoxer::AiReply.ready?("claude", JSON.generate(type: "result", is_error: true, result: "Matron is ready"))
    assert DevBoxer::AiReply.ready?("codex", JSON.generate(type: "item.completed", item: {type: "agent_message", text: "Matron is ready"}))
    refute DevBoxer::AiReply.ready?("codex", JSON.generate(type: "error", message: "Failed prompt: Matron is ready"))
    refute DevBoxer::AiReply.ready?("codex", JSON.generate(type: "item.completed", item: {type: "command_execution", text: "Matron is ready"}))
    refute DevBoxer::AiReply.ready?("claude", "not JSON")
  end
end
