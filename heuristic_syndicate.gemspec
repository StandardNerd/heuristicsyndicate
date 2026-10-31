# frozen_string_literal: true

require_relative "lib/heuristic_syndicate/version"

Gem::Specification.new do |spec|
  spec.name          = "heuristic_syndicate"
  spec.version       = HeuristicSyndicate::VERSION
  spec.authors       = ["Joon Ki Choi"]
  spec.summary       = "A Ruby Framework for Governed, Durable and Observable AI Workflows"
  spec.description   = "Extends ruby_llm with graph orchestration, at-least-once durable execution, " \
                       "capability-based security, multi-tenancy, versioned action governance, and tamper-evident auditing."
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.4.5"

  spec.files = Dir.chdir(__dir__) do
    Dir["{lib,examples,docs}/**/*", "LICENSE", "README.md", "architecture_decision_record.md", "spike1_spike2.md"]
      .select { |f| File.file?(f) }
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby_llm", "~> 2.1"
end
