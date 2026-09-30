//
// BuildCheckJSON.swift
//
// Models asked for "ONLY a JSON object" still wrap it in ```json fences or a
// sentence of prose often enough to matter. This finds the object anyway.
// Foundation only.
//

import Foundation

enum BuildCheckJSON {
    /// The outermost `{…}` in a model reply, parsed. Nil when there is none
    /// or it isn't valid JSON - callers treat that as an unreadable reply.
    static func object(in reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end else { return nil }
        let data = Data(String(reply[start...end]).utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
