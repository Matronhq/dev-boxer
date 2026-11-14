require "json"

module DevBoxer
  module AiReply
    def self.ready?(provider, output)
      if provider == "claude"
        message = JSON.parse(output)
        message["type"] == "result" && !message["is_error"] && message["result"].to_s.strip == "Matron is ready"
      else
        output.lines.any? do |line|
          event = JSON.parse(line)
          event["type"] == "item.completed" && event.dig("item", "type") == "agent_message" && event.dig("item", "text").to_s.strip == "Matron is ready"
        end
      end
    rescue JSON::ParserError, TypeError
      false
    end
  end
end
