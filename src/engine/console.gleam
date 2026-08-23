//// Minimal stdin/stdout interaction for the interactive CLI, plus a
//// millisecond clock reading. These are the only I/O primitives Gleam's
//// stdlib doesn't provide; both are thin wrappers around Erlang functions

import gleam/int
import gleam/io
import gleam/string

@external(erlang, "interactive_ffi", "prompt_line")
fn prompt_line(prompt: String) -> Result(String, Nil)

@external(erlang, "interactive_ffi", "now_ms")
pub fn now_ms() -> Int

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> a

@external(erlang, "interactive_ffi", "try_run")
pub fn try_run(f: fn() -> a) -> Result(a, Nil)

/// Print `prompt` and read a line of input. EOF (Ctrl-D / Ctrl-Z, or the
/// input stream closing) ends the program cleanly rather than looping.
fn read_line(prompt: String) -> String {
  case prompt_line(prompt) {
    Ok(line) -> line
    Error(Nil) -> {
      io.println("")
      halt(0)
    }
  }
}

/// Prompt until the user enters an integer >= `min`.
pub fn ask_int(prompt: String, min: Int) -> Int {
  case int.parse(string.trim(read_line(prompt))) {
    Ok(n) if n >= min -> n
    _ -> {
      io.println("  enter an integer >= " <> int.to_string(min))
      ask_int(prompt, min)
    }
  }
}

/// Prompt until the user enters an integer within `min..max` (inclusive).
pub fn ask_int_range(prompt: String, min: Int, max: Int) -> Int {
  case int.parse(string.trim(read_line(prompt))) {
    Ok(n) if n >= min && n <= max -> n
    _ -> {
      io.println(
        "  enter an integer between "
        <> int.to_string(min)
        <> " and "
        <> int.to_string(max),
      )
      ask_int_range(prompt, min, max)
    }
  }
}

/// Block until the user presses Enter.
pub fn wait_enter(prompt: String) -> Nil {
  let _ = read_line(prompt)
  Nil
}
