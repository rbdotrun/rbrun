require "test_helper"

class LineBufferTest < Minitest::Test
  def setup
    @lines = []
    @buf = Rbrun::Sandbox::LineBuffer.new(->(line) { @lines << line })
  end

  def test_emits_one_call_per_complete_line
    @buf.feed("part-of-")
    assert_empty @lines
    @buf.feed("line-1\npart-of-line-2")
    assert_equal [ "part-of-line-1\n" ], @lines
    @buf.flush
    assert_equal [ "part-of-line-1\n", "part-of-line-2" ], @lines
  end

  def test_flush_is_idempotent
    @buf.feed("x\n")
    @buf.flush
    @buf.flush
    assert_equal [ "x\n" ], @lines
  end

  def test_multiple_lines_in_one_chunk
    @buf.feed("a\nb\nc\n")
    assert_equal [ "a\n", "b\n", "c\n" ], @lines
  end
end
