import Foundation

/// A preview only. Availability is supplied by the permission-gated adapter,
/// never by public action arguments. The clock is injectable only in tests.
enum CalendarProposal {
    struct Request: Sendable {
        let range: CalendarBusyBlock
        let title: String
        let zone: TimeZone
        let zoneName: String
        let duration: Int
        let limit: Int
        let guests: [String]
        let proposed: [Date]?

        init(_ args: [String: Any]) throws {
            range = try CalendarFreeBusy.range(args)
            func invalid() -> AgentError { AgentError("INVALID_ARGUMENTS", "Provide a title, IANA time_zone, duration_minutes (1–480), limit (1–20), and optional guest labels or proposed_starts.") }
            func label(_ value: Any?) throws -> String {
                guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.unicodeScalars.count <= 200,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid() }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func integer(_ key: String, _ fallback: Int, _ maximum: Int) throws -> Int {
                guard let value = args[key] else { return fallback }
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= 1, n.doubleValue <= Double(maximum) else { throw invalid() }
                return n.intValue
            }
            title = try label(args["title"])
            guard let name = args["time_zone"] as? String,
                  name == "UTC" || name.range(of: #"^[A-Za-z_]+(?:/[A-Za-z0-9_+\-]+)+$"#, options: .regularExpression) != nil,
                  let zone = TimeZone(identifier: name) else { throw invalid() }
            self.zone = zone; zoneName = name
            duration = try integer("duration_minutes", 30, 480)
            limit = try integer("limit", 5, 20)
            if let value = args["guests"] {
                guard let values = value as? [String], values.count <= 20 else { throw invalid() }
                guests = try values.map(label)
            } else { guests = [] }
            if let value = args["proposed_starts"] {
                guard let values = value as? [String], !values.isEmpty, values.count <= 100 else { throw invalid() }
                proposed = try values.map { value in
                    guard let date = CalendarFreeBusy.instant(value) else { throw invalid() }
                    return date
                }
            } else { proposed = nil }
        }
    }

    static func result(_ request: Request, availability: [String: Any], now: Date) throws -> [String: Any] {
        guard availability["complete"] as? Bool == true, availability["scope"] as? String == "own_calendar",
              let raw = availability["busy"] as? [[String: String]] else {
            throw AgentError("INCOMPLETE_AVAILABILITY", "A complete own-calendar read is required before proposing times.")
        }
        let busy = try CalendarFreeBusy.merge(raw.map { block in
            guard let start = block["start"].flatMap(CalendarFreeBusy.instant),
                  let end = block["end"].flatMap(CalendarFreeBusy.instant), end > start else {
                throw AgentError("INCOMPLETE_AVAILABILITY", "Invalid busy interval; no proposal was returned.")
            }
            return CalendarBusyBlock(start: start, end: end)
        }, in: request.range)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = request.zone
        let seconds = Double(request.duration * 60)
        var starts: [Date] = []
        if let proposed = request.proposed {
            starts = Array(Set(proposed)).sorted()
        } else {
            // Scan absolute minutes, then check the local grid. This handles DST
            // folds/gaps and fractional-hour zones without inventing local times.
            var start = Date(timeIntervalSince1970: ceil(max(request.range.start, now).timeIntervalSince1970 / 60) * 60)
            while start.addingTimeInterval(seconds) <= request.range.end {
                let end = start.addingTimeInterval(seconds)
                let a = calendar.dateComponents([.hour, .minute, .second], from: start)
                let b = calendar.dateComponents([.hour, .minute, .second], from: end)
                if a.hour! >= 9, a.hour! < 18, a.minute! % 15 == 0, a.second == 0,
                   calendar.isDate(start, inSameDayAs: end),
                   b.hour! * 60 + b.minute! <= 18 * 60, b.second == 0 { starts.append(start) }
                start = start.addingTimeInterval(60)
            }
        }
        // The busy intervals are sorted. Advance a cursor instead of scanning
        // up to 10,000 events for every candidate in a month-long request.
        var cursor = 0
        let candidates = starts.filter { start in
            let end = start.addingTimeInterval(seconds)
            guard start >= now, start >= request.range.start, end <= request.range.end else { return false }
            while cursor < busy.count && busy[cursor].end <= start { cursor += 1 }
            return cursor == busy.count || busy[cursor].start >= end
        }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let slots = candidates.prefix(request.limit).map { ["start": formatter.string(from: $0), "end": formatter.string(from: $0.addingTimeInterval(seconds))] }
        let preview: [String: Any] = ["title": request.title, "start": slots.first?["start"] as Any? ?? NSNull(),
            "end": slots.first?["end"] as Any? ?? NSNull(), "time_zone": request.zoneName,
            "duration_minutes": request.duration, "guests": request.guests, "guest_count": request.guests.count,
            "calendar_scope": "own_calendar", "send_invitations": false, "requires_human_book": true,
            "video_link": NSNull(), "complete": !slots.isEmpty]
        return ["slots": slots, "candidate_count": candidates.count, "truncated": candidates.count > request.limit,
                "preview": preview, "availability": availability, "dry_run": true, "side_effects": false,
                "booked": false, "booking_supported": false, "teammate_availability": "unknown",
                "slot_source": request.proposed == nil ? "workday_grid" : "proposed_starts"]
    }

    static func readAndPropose(_ args: [String: Any]) async throws -> [String: Any] {
        let request = try Request(args)
        let availability = try await CalendarFreeBusyReader.read(args)
        return try result(request, availability: availability, now: Date())
    }
}
