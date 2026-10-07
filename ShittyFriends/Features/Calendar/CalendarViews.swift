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
            VStack(alignment: .leading, spacing: 16) {
                if subject == .me { subjectPicker }
                monthHeader
                MonthGrid(month: month, byDay: byDay, selected: $selectedDay, accent: accent, calendar: cal)
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
                    .buttonStyle(.sticker(Palette.card, ink: Palette.ink, height: 52))
                }
            }
            .gutter()
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(Palette.paper.ignoresSafeArea())
        .sheet(item: $editing) { e in EventEditorView(event: e).environment(model) }
        .sheet(isPresented: $addingMissed) { AddMissedView(defaultDay: selectedDay).environment(model) }

        if subject == .me {
            NavigationStack { content.toolbar(.hidden, for: .navigationBar) }
        } else {
            content.navigationTitle("CALENDAR").navigationBarTitleDisplayMode(.inline)
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
            Button { withAnimation(Motion.snappy) { month = month.adding(months: -1) } } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .black)).frame(width: 44, height: 44)
            }
            Spacer()
            Text(date.formatted(.dateTime.month(.wide).year()).uppercased())
                .font(.display(22))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Button { withAnimation(Motion.snappy) { month = month.adding(months: 1) } } label: {
                Image(systemName: "chevron.right").font(.system(size: 18, weight: .black)).frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(Palette.ink)
    }

    private func monthStats(byDay: [DayKey: [PoopEvent]]) -> some View {
        let cal = store.calendar
        let date = cal.date(from: DateComponents(year: month.year, month: month.month, day: 15)) ?? Date()
        let s = StatsCalculator.compute(events, in: CalendarMath.monthInterval(date, calendar: cal), now: Date(), calendar: cal)
        return HStack(spacing: 10) {
            StatTile(value: "\(s.total)", label: "POOPS", fill: accent.color)
            StatTile(value: "\(s.activeDays)", label: "DAYS")
            StatTile(value: s.longestSession.map { StatsCalculator.formatDuration($0) } ?? "—", label: "LONGEST")
            StatTile(value: "\(s.uniquePlaces)", label: "PLACES")
        }
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

// MARK: - Grid

struct MonthGrid: View {
    var month: MonthKey
    var byDay: [DayKey: [PoopEvent]]
    @Binding var selected: DayKey?
    var accent: IdentityColor
    var calendar: Calendar

    var body: some View {
        let cells = CalendarMath.monthGrid(month, calendar: calendar)
        let today = DayKey(Date(), calendar: calendar)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i])
                        .font(.heading(12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    if let day = cell {
                        DayCell(day: day, count: byDay[day]?.count ?? 0, social: byDay[day]?.contains { $0.pwmSessionID != nil || $0.partyID != nil } ?? false, located: byDay[day]?.contains { $0.location != nil } ?? false, isToday: day == today, isSelected: day == selected, accent: accent)
                            .onTapGesture {
                                Haptics.tick()
                                withAnimation(Motion.snappy) { selected = day }
                            }
                    } else {
                        Color.clear.frame(height: 58)
                    }
                }
            }
        }
        .padding(10)
        .sticker(Palette.card, radius: 24, shadow: 4)
    }
}

struct DayCell: View {
    var day: DayKey
    var count: Int
    var social: Bool
    var located: Bool
    var isToday: Bool
    var isSelected: Bool
    var accent: IdentityColor

    var body: some View {
        VStack(spacing: 2) {
            Text("\(day.day)")
                .font(.heading(12))
                .foregroundStyle(isSelected ? accent.ink : Palette.ink)
            ZStack {
                ForEach(0..<min(count, 3), id: \.self) { i in
                    Circle()
                        .fill(Palette.poop)
                        .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1.2))
                        .frame(width: 14 - CGFloat(i) * 2.5, height: 14 - CGFloat(i) * 2.5)
                        .offset(y: CGFloat(-i) * 7 + 6)
                }
                if count > 3 {
                    Text("\(count)")
                        .font(.heading(9))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Palette.tomato))
                        .offset(x: 12, y: -8)
                }
            }
            .frame(height: 30)
            HStack(spacing: 2) {
                if social { Circle().fill(Palette.pink).frame(width: 5, height: 5) }
                if located { Circle().fill(Palette.aqua).frame(width: 5, height: 5) }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? accent.color : (count > 0 ? accent.color.opacity(0.18) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isToday ? Palette.line : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.day), \(count) poops")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

struct EventRow: View {
    var event: PoopEvent
    var partners: [String] = []
    var editable = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("💩").font(.system(size: 28))
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
        .sticker(Palette.card, radius: 18, shadow: 3, stroke: 2)
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
    @State private var shared = true
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("WHEN") {
                    DatePicker("Start", selection: $start, in: ...Date())
                    if event.source != .instant {
                        Toggle("Has an end time", isOn: $hasEnd)
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
                }
                Section("WHERE") {
                    if hasLocation {
                        TextField("Place name", text: $placeName)
                        Button("Remove location", role: .destructive) {
                            hasLocation = false
                            pendingLocation = nil
                        }
                    } else {
                        Button(locating ? "Locating…" : "Use current location") {
                            locating = true
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
                        .disabled(!model.location.isAuthorized || locating)
                        if !model.location.isAuthorized {
                            Text("Allow location in Settings to attach one.").font(.footnote).foregroundStyle(.secondary)
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
                            Button("Remove") { location = nil }
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
