# frozen_string_literal: true

module ReplyFilter
  module_function

  def did_from_at_uri(uri)
    uri.to_s[%r{\Aat://([^/]+)/}, 1]
  end

  def own_reply?(record, repo_did)
    reply = record["reply"]
    return false unless reply && repo_did

    parent_did = did_from_at_uri(reply.dig("parent", "uri"))
    return parent_did == repo_did if parent_did

    did_from_at_uri(reply.dig("root", "uri")) == repo_did
  end

  def reply_to_other_user?(record, repo_did)
    return false unless record["reply"] && repo_did

    !own_reply?(record, repo_did)
  end
end
