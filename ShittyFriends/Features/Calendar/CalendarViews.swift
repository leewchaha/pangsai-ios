import SwiftUI

enum CalendarSubject: Hashable {
    case me
    case friend(UserID)
}

struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    var subject: CalendarSubject = .me

    @State private var selectedSubject: CalendarSubject = .me
    @State private var month = MonthKey(Date(), calendar: CalendarMath.standard())
    /// +1 = moved to a later month (slides in from the right), -1 = earlier.
    @State private var slideDirection = 1
    @State private var selectedDay: DayKey? = DayKey(Date(), calendar: CalendarMath.standard())
    @State private var editing: PoopEvent?
    @State private var addingMissed = false

    private var store: Store { model.store }
    private var current: CalendarSubject { subject == .me ? selectedSubject : subject }
    private var isMine: Bool { current == .me }

    private var events: [PoopEvent] {
        switch current {
        case .me: return store.sortedEvents
        case .friend(let uid): return store.friendEvents(uid)
        }
    }

    private var accent: IdentityColor {
        switch current {
        case .me: return store.profile.color
        case .friend(let uid): return store.person(for: uid)?.color ?? .violet
        }
    }

    var body: some View {
        let cal = store.calendar
        let byDay = Dictionary(grouping: events) { DayKey($0.startedAt, calendar: cal) }
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if subject == .me { subjectPicker }
                monthHeader
                monthPager(byDay: byDay, calendar: cal)
                monthStats(byDay: byDay)
                if let day = selectedDay {
                    dayDetail(day, events: (byDay[day] ?? []).sorted { $0.startedAt < $1.startedAt })
                }
                if isMine {
                    Button {
                        addingMissed = true
                    } label: {
                        Label("ADD MISSED POOP", systemImage: "plus")
                    }
                    .font(.heading(11))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .calmSurface(Palette.card, radius: 16)
                    .buttonStyle(PressableStyle())
                }
            }
            .gutter()
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .clearsTabBar()
        .background(Palette.paper.ignoresSafeArea())
        .sheet(item: $editing) { e in EventEditorView(event: e).environment(model) }
        .sheet(isPresented: $addingMissed) { AddMissedView(defaultDay: selectedDay).environment(model) }

        if subject == .me {
            NavigationStack { content.toolbar(.hidden, for: .navigationBar) }
        } else {
            content.navigationTitle("CALENDAR").navigationBarTitleDisplayMode(.inline)
        }
    }

    /// One month at a time, only as many week rows as the month needs (no empty 6th row).
    /// Swipe left/right (or the chevrons) to change month; taps still select days.
    private func monthPager(byDay: [DayKey: [PoopEvent]], calendar: Calendar) -> some View {
        MonthGrid(month: month, byDay: byDay, selected: $selectedDay, accent: accent, calendar: calendar)
            .id(month)
            .transition(.asymmetric(
                insertion: .move(edge: slideDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: slideDirection > 0 ? .leading : .trailing).combined(with: .opacity)
            ))
            .frame(maxWidth: .infinity)
            .clipped()
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let dx = value.translation.width
                        guard abs(dx) > 50, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                        moveMonth(by: dx < 0 ? 1 : -1)
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityHint("Swipe left or right to change month")
    }

    private func moveMonth(by delta: Int) {
        Haptics.tick()
        // Direction first, month on the next turn: the outgoing grid must render once with the new
        // direction, or reversing direction slides it out the wrong way.
        slideDirection = delta >= 0 ? 1 : -1
        DispatchQueue.main.async {
            withAnimation(Motion.snappy) {
                month = month.adding(months: delta)
                // Don't show the previous month's day log under the new month.
                if let day = selectedDay, day.year != month.year || day.month != month.month {
                    selectedDay = nil
                }
            }
        }
    }

    // MARK: Pieces

    private var subjectPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button { selectedSubject = .me } label: { Chip(text: "ME", selected: selectedSubject == .me) }
                ForEach(store.friendSummaries()) { f in
                    Button { selectedSubject = .friend(f.person.id) } label: {
                        Chip(text: "@" + f.person.handle.uppercased(), selected: selectedSubject == .friend(f.person.id))
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var monthHeader: some View {
        let cal = store.calendar
        let date = cal.date(from: DateComponents(year: month.year, month: month.month, day: 1)) ?? Date()
        return HStack {
            Button { moveMonth(by: -1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .black)).frame(width: 44, height: 44)
            }
            Spacer()
            Text(date.formatted(.dateTime.month(.wide).year()).uppercased())
                .font(.display(22))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Button { moveMonth(by: 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 18, weight: .black)).frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(Palette.ink)
    }

    private func monthStats(byDay: [DayKey: [PoopEvent]]) -> some View {
        let cal = store.calendar
        let date = cal.date(from: DateComponents(year: month.year, month: month.month, day: 15)) ?? Date()
        let s = StatsCalculator.compute(events, in: CalendarMath.monthInterval(date, calendar: cal), now: Date(), calendar: cal)
        return HStack(spacing: 0) {
            CalendarMetric(value: "\(s.total)", label: "POOPS", accent: accent.color)
            Divider().frame(height: 30)
            CalendarMetric(value: "\(s.activeDays)", label: "DAYS", accent: Palette.lime)
            Divider().frame(height: 30)
            CalendarMetric(value: s.longestSession.map { StatsCalculator.formatDuration($0) } ?? "—", label: "LONGEST", accent: Palette.sun)
            Divider().frame(height: 30)
            CalendarMetric(value: "\(s.uniquePlaces)", label: "PLACES", accent: Palette.aqua)
        }
        .padding(.vertical, 10)
        .calmSurface(Palette.card, radius: 18)
    }

    private func dayDetail(_ day: DayKey, events: [PoopEvent]) -> some View {
        let date = day.startDate(calendar: store.calendar)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(date.formatted(.dateTime.month(.wide).day()).uppercased() + " · \(events.count)")
            if events.isEmpty {
                Text("No poops logged.").font(.ui(14, .medium)).foregroundStyle(Palette.muted)
            }
            ForEach(events) { e in
                Button {
                    if isMine { editing = store.my.events[e.id] }
                } label: {
                    EventRow(event: e, partners: partners(for: e), editable: isMine)
                }
                .buttonStyle(PressableStyle())
                .disabled(!isMine)
            }
        }
    }

    private func partners(for e: PoopEvent) -> [String] {
        guard let sid = e.pwmSessionID else { return [] }
        if let archived = store.my.pwmArchive[sid] {
            return archived.participants.filter { $0.id != store.userID }.map { "@" + $0.handle }
        }
        if let v = store.liveSession(sid) {
            return v.participants.filter { $0.id != store.userID && ($0.status == .joined || $0.status == .done) }.map { "@" + $0.person.handle }
        }
        return []
    }
}


struct CalendarMetric: View {
    var value: String
    var label: String
    var accent: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.digits(18)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.5)
            HStack(spacing: 3) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text(label).font(.heading(9)).foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Grid

struct MonthGrid: View {
    var month: MonthKey
    var byDay: [DayKey: [PoopEvent]]
    @Binding var selected: DayKey?
    var accent: IdentityColor
    var calendar: Calendar

    var body: some View {
        // Only the rows this month needs (4–6), so short months don't leave a blank band.
        let cells: [DayKey?] = CalendarMath.monthGrid(month, calendar: calendar)
        let today = DayKey(Date(), calendar: calendar)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i])
                        .font(.heading(10))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    if let day = cell {
                        let dayEvents = byDay[day] ?? []
                        DayCell(day: day, count: dayEvents.count, social: dayEvents.contains { $0.pwmSessionID != nil || $0.partyID != nil }, isToday: day == today, isSelected: day == selected, accent: accent)
                            .onTapGesture {
                                Haptics.tick()
                                withAnimation(Motion.snappy) { selected = day }
                            }
                    } else {
                        Color.clear.frame(height: DayCell.height)
                    }
                }
            }
        }
        .padding(8)
        .calmSurface(Palette.card, radius: 20)
    }
}

struct DayCell: View {
    static let height: CGFloat = 42

    var day: DayKey
    var count: Int
    /// Poop With Me / party that day: a small pink corner dot.
    var social: Bool
    var isToday: Bool
    var isSelected: Bool
    var accent: IdentityColor

    var body: some View {
        VStack(spacing: 1) {
            Text("\(day.day)")
                .font(.heading(11))
                .foregroundStyle(isSelected ? accent.ink : Palette.ink)
            HStack(alignment: .center, spacing: -3) {
                // Object3DImage uses the shared cached snapshot. Repeating it in
                // calendar cells never creates live SceneKit renderers per day.
                ForEach(0..<min(count, 3), id: \.self) { _ in
                    Object3DImage(subject: .poop(.classic), size: count >= 3 ? 11 : 13)
                }
                if count > 3 {
                    // Up to three poops are drawn; the rest is an exact "+n" (never a "?").
                    Text("+\(count - 3)")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(isSelected ? accent.ink : Palette.ink)
                        .padding(.leading, 3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 15)
        }
        .frame(maxWidth: .infinity, minHeight: DayCell.height, maxHeight: DayCell.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? accent.color : (count > 0 ? accent.color.opacity(0.18) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isToday ? Palette.line : Color.clear, lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            if social {
                Circle().fill(Palette.pink).frame(width: 6, height: 6).padding(4)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.day), \(count) poops\(social ? ", with friends" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

struct EventRow: View {
    var event: PoopEvent
    var partners: [String] = []
    var editable = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Same faceless 3D poop as the day cells and the map, never the emoji.
            Object3DImage(subject: .poop(.classic), size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.startedAt.shortTime).font(.heading(17))
                    if event.isLive {
                        Text("LIVE").font(.heading(10)).foregroundStyle(Palette.inkFixed).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Palette.sun))
                    }
                }
                if let l = event.location {
                    Text("📍 " + l.label).font(.ui(14, .semibold))
                }
                if let d = event.duration {
                    Text(StatsCalculator.formatDurationWords(d) + (event.isSuspicious(now: Date()) ? "  ⚠️ fix?" : ""))
                        .font(.ui(13, .medium))
                } else if event.source == .instant {
                    Text("instant log").font(.ui(13, .medium)).foregroundStyle(Palette.muted)
                }
                if !partners.isEmpty {
                    Text("Poop With Me · " + partners.joined(separator: ", ")).font(.ui(13, .semibold)).foregroundStyle(Palette.pink)
                } else if event.pwmSessionID != nil {
                    Text("Poop With Me").font(.ui(13, .semibold)).foregroundStyle(Palette.pink)
                }
                if event.partyID != nil {
                    Text("Poop Party").font(.ui(13, .semibold)).foregroundStyle(Palette.tangerine)
                }
                if event.source == .manual {
                    Text("added later").font(.ui(12, .medium)).foregroundStyle(Palette.muted)
                } else if event.imported {
                    Text("imported").font(.ui(12, .medium)).foregroundStyle(Palette.muted)
                } else if event.manuallyAdjusted {
                    Text("edited").font(.ui(12, .medium)).foregroundStyle(Palette.muted)
                }
            }
            .foregroundStyle(Palette.ink)
            Spacer()
            if editable {
                Image(systemName: "pencil").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.muted)
            }
        }
        .padding(12)
        .calmSurface(Palette.card, radius: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor

struct EventEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var event: PoopEvent

    @State private var start = Date()
    @State private var hasEnd = false
    @State private var end = Date()
    @State private var placeName = ""
    @State private var hasLocation = false
    /// A freshly captured location, applied only when the user taps Save (with the other edits).
    @State private var pendingLocation: PoopLocation?
    @State private var locating = false
    @State private var query = ""
    @State private var results: [PoopLocation] = []
    @State private var shared = true
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("WHEN") {
                    DatePicker("Start", selection: $start, in: ...Date())
                    if event.source != .instant {
                        // A finished timer always keeps an end time (clearing it would fake "currently pooping").
                        if !(event.source == .timed && !event.isLive) {
                            Toggle(event.isLive ? "End this session" : "Has an end time", isOn: $hasEnd)
                        }
                        if hasEnd {
                            DatePicker("End", selection: $end, in: start...max(start, Date().addingTimeInterval(60)))
                            Text("Duration " + StatsCalculator.formatDurationWords(max(0, end.timeIntervalSince(start))))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if event.isSuspicious(now: Date()) {
                        Text("This timer ran unusually long. Forgot to tap DONE? Fix the end time — nothing gets deleted.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if event.countsForRanking {
                        Text("Changing the start time, or the pin's position, keeps this poop in your history and stats but takes it out of leaderboards, trophies and achievements.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("WHERE") {
                    if hasLocation {
                        // Pins can be renamed, never removed: every poop is on the map.
                        TextField("Place name", text: $placeName)
                    } else {
                        TextField("Search a place", text: $query)
                            .onSubmit { Task { results = await model.location.search(query) } }
                        ForEach(results.prefix(5), id: \.self) { r in
                            Button(r.label + (r.locality.map { " · " + $0 } ?? "")) {
                                pendingLocation = r
                                placeName = r.label
                                hasLocation = true
                            }
                        }
                        Button(locating ? "Locating…" : "Use current location") {
                            locating = true
                            Task {
                                // Asks iOS the first time; a denied permission is handled below.
                                guard await model.location.requestAuthorization() else {
                                    locating = false
                                    return
                                }
                                model.location.locateOnce { loc in
                                    locating = false
                                    guard let loc else {
                                        model.info("NO LOCATION", "Couldn't get a fix. Try again outside.")
                                        return
                                    }
                                    pendingLocation = loc
                                    placeName = loc.label
                                    hasLocation = true
                                }
                            }
                        }
                        .disabled(model.location.isDenied || locating)
                        if model.location.isDenied {
                            Text("Location is off for ShittyFriends in iOS Settings. Search a place instead, or turn it back on.").font(.footnote).foregroundStyle(.secondary)
                            OpenSystemSettingsButton()
                        }
                    }
                }
                Section {
                    Toggle("Share to my groups", isOn: $shared)
                } footer: {
                    Text("Friends always see your full history. This only controls what your groups see.")
                }
                Section {
                    Button("Delete this poop", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(event.startedAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold() }
            }
            .confirmationDialog("Delete this poop?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.store.delete(event.id)
                    dismiss()
                }
            } message: {
                Text(event.halfPoints > 0 ? "It disappears from your history and your friends'. The \(formatHalfPoints(event.halfPoints)) points it earned stay yours." : "It disappears from your history and your friends'.")
            }
            .onAppear {
                start = event.startedAt
                hasEnd = event.endedAt != nil
                end = event.endedAt ?? (event.isLive ? Date() : event.startedAt.addingTimeInterval(5 * 60))
                hasLocation = event.location != nil
                placeName = event.location?.label ?? ""
                shared = event.sharedToGroups
            }
        }
    }

    private func save() {
        var location: PoopLocation?? = nil
        if !hasLocation {
            if event.location != nil { location = .some(nil) }
        } else if var l = pendingLocation ?? event.location {
            let name = placeName.trimmingCharacters(in: .whitespaces)
            if ContentFilter.isBlocked(name) {
                model.info("NOT THAT NAME", "Pick a different place name.")
                return
            }
            if !name.isEmpty, name != l.label { l.placeName = String(name.prefix(40)) }
            if l != event.location { location = .some(l) }
        }
        let endValue: Date?? = event.source == .instant ? nil : .some(hasEnd ? max(start, end) : nil)
        model.store.edit(event.id, start: start, end: endValue, location: location, sharedToGroups: shared)
        dismiss()
    }
}

// MARK: - Add missed

struct AddMissedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var defaultDay: DayKey?

    @State private var start = Date()
    @State private var withDuration = false
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var query = ""
    @State private var results: [PoopLocation] = []
    @State private var location: PoopLocation?

    var body: some View {
        NavigationStack {
            Form {
                Section("DATE & TIME") {
                    DatePicker("When", selection: $start, in: ...Date())
                }
                Section("DURATION (OPTIONAL)") {
                    Toggle("I know how long", isOn: $withDuration)
                    if withDuration {
                        Stepper("\(minutes) min", value: $minutes, in: 0...120)
                        Stepper("\(seconds) sec", value: $seconds, in: 0...59, step: 5)
                    }
                }
                Section("LOCATION (OPTIONAL)") {
                    if let l = location {
                        HStack {
                            Text("📍 " + l.label)
                            Spacer()
                            Button("Change") { location = nil }
                        }
                    } else {
                        TextField("Search a place", text: $query)
                            .onSubmit { Task { results = await model.location.search(query) } }
                        ForEach(results.prefix(5), id: \.self) { r in
                            Button(r.label + (r.locality.map { " · " + $0 } ?? "")) { location = r }
                        }
                        if model.location.isAuthorized {
                            Button("Use current location") {
                                model.location.locateOnce { loc in location = loc }
                            }
                        }
                    }
                }
                Section {
                    Text("Added later — it counts, it shows in your history, and it won't tell anyone you're pooping right now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("ADD MISSED POOP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ADD") {
                        let d: TimeInterval? = withDuration ? TimeInterval(minutes * 60 + seconds) : nil
                        model.store.addManual(at: start, duration: d, location: location)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                if let day = defaultDay, day != DayKey(Date(), calendar: model.store.calendar) {
                    start = day.startDate(calendar: model.store.calendar).addingTimeInterval(12 * 3600)
                }
            }
        }
    }
}
