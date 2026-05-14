# frozen_string_literal: true

module ObsidianBlock
  START_MARKER = "<!-- bsky-to-obsidian:start -->"
  END_MARKER = "<!-- bsky-to-obsidian:end -->"

  module_function

  def replace_or_append(note, body)
    start_index = note.index(START_MARKER)
    end_index = note.index(END_MARKER)

    if start_index && end_index && end_index > start_index
      body_start = start_index + START_MARKER.length

      before = note[0...body_start].rstrip
      after = note[end_index..].to_s.lstrip

      [
        before,
        body.rstrip,
        after
      ].join("\n").rstrip + "\n"
    else
      [
        note.rstrip,
        "",
        START_MARKER,
        body.rstrip,
        END_MARKER
      ].join("\n").rstrip + "\n"
    end
  end

  def remove(note)
    start_index = note.index(START_MARKER)
    end_index = note.index(END_MARKER)

    return [note, false] unless start_index && end_index && end_index > start_index

    end_index += END_MARKER.length

    before = note[0...start_index].rstrip
    after = note[end_index..].to_s.lstrip

    updated =
      if before.empty?
        after
      elsif after.empty?
        before + "\n"
      else
        before + "\n\n" + after
      end

    [updated, true]
  end
end
