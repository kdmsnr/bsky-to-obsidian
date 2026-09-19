# frozen_string_literal: true

module ObsidianBlock
  START_MARKER = "<!-- bsky-to-obsidian:start -->"
  END_MARKER = "<!-- bsky-to-obsidian:end -->"

  module_function

  def replace_or_append(note, body, name: "bsky-to-obsidian")
    start_marker = "<!-- #{name}:start -->"
    end_marker = "<!-- #{name}:end -->"
    start_index = note.index(start_marker)
    end_index = note.index(end_marker)

    if start_index && end_index && end_index > start_index
      body_start = start_index + start_marker.length

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
        start_marker,
        body.rstrip,
        end_marker
      ].join("\n").rstrip + "\n"
    end
  end

  def remove(note, name: "bsky-to-obsidian")
    start_marker = "<!-- #{name}:start -->"
    end_marker = "<!-- #{name}:end -->"
    start_index = note.index(start_marker)
    end_index = note.index(end_marker)

    return [note, false] unless start_index && end_index && end_index > start_index

    end_index += end_marker.length

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
