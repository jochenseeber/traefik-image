# frozen_string_literal: true

require "minitest/autorun"
require "rake"

# The Rakefile is the code under test, so it is loaded rather than required.
# Loading defines its classes, its IMAGE and its tasks in this process.
load File.expand_path("../Rakefile", __dir__)

# A command runner that records what it was asked to do and runs nothing, so no
# test starts Docker or git.
#
# A capture answers from `captures` by exact arguments, else from the block, which
# lets a test answer commands whose arguments it cannot know in advance, such as
# a generated container name.
class FakeCommands
  attr_reader :executed, :captured

  def initialize(captures: {}, &responder)
    @captures = captures
    @responder = responder || ->(_arguments) {}
    @executed = []
    @captured = []
  end

  def execute(*arguments, **)
    @executed << arguments
  end

  def capture(*arguments, **)
    answer(arguments)
  end

  def capture_merged(*arguments)
    answer(arguments)
  end

  private

  def answer(arguments)
    @captured << arguments
    @captures.fetch(arguments) { @responder.call(arguments) }
  end
end
