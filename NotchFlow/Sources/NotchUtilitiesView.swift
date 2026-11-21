import EventKit
import SwiftUI

struct NotchUtilitiesView: View {
    @ObservedObject var utilities: UtilityCapabilityService

    private var visibleDayEvents: [EKEvent] {
        // Re-filtered on every render as well as on refresh: an event that ended
        // while the pane sat open must not linger at the top of the list.
        let now = Date()
        let upcoming = utilities.upcomingEvents.filter { $0.endDate > now }
        guard let first = upcoming.first else { return [] }
        return upcoming.filter { Calendar.current.isDate($0.startDate, inSameDayAs: first.startDate) }
    }

    private func dayLabel(for date: Date) -> String {
        Calendar.current.isDateInTomorrow(date)
            ? "Tomorrow"
            : date.formatted(.dateTime.weekday(.wide).month().day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            joinChip
            if utilities.calendarPermission == .authorized, let first = visibleDayEvents.first {
                // Only when the list is NOT today's — the header already names
                // today, and repeating it above the rows read as a duplicate.
                if !Calendar.current.isDateInToday(first.startDate) {
                    Text(dayLabel(for: first.startDate))
                        .font(.sf(10.5, weight: .medium)).foregroundStyle(Tokens.text3)
                }
                if visibleDayEvents.count > NotchUtilitiesLayout.maximumVisibleRows {
                    ScrollView {
                        eventRows
                    }
                    .frame(height: 108)
                    .scrollIndicators(.hidden)
                } else {
                    eventRows
                }
            } else {
                emptyState
            }
        }
        .padding(10)
        // Width as well as height, for the same reason as the File tray: the
        // background must fill this card's column so the two cards are visually
        // equal and the gap between them is the layout's real gutter.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Only while this pane is on screen: weather nobody is looking at is a
        // network request nobody asked for. The service itself no-ops when the
        // reading is still fresh, so reopening the pane costs nothing.
        .task { await utilities.refreshWeather() }
        // The calendar too: the pane is where the list is looked at, so it is
        // re-read each time the pane appears rather than trusted from launch.
        .task { await utilities.refreshCalendar() }
    }

    /// One calm line under the header — never a stale or half-empty list. The
    /// header above already carries today's date and the time, so the card still
    /// reads as a calendar on an empty day.
    @ViewBuilder private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: utilities.calendarPermission == .authorized ? "calendar" : "calendar.badge.exclamationmark")
                .font(.system(size: 11, weight: .medium))
            Text(utilities.calendarPermission == .authorized
                 ? "Nothing scheduled this week"
                 : "Allow full Calendar access to see events")
                .font(.sf(11, weight: .regular))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Tokens.text3)
        .padding(.top, 2)
    }

    /// Today's date and the wall clock, beside the section's name — so the panel
    /// answers "what day is it, what time is it" even on a day with no events at
    /// all (where the tray used to say only "No upcoming events").
    ///
    /// `TimelineView(.everyMinute)` rather than a `Timer`: the system wakes it on
    /// the minute boundary, so the clock never sits a stale 59 seconds behind and
    /// the date rolls over at midnight on its own.
    private var header: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Calendar").font(.sf(11, weight: .semibold)).foregroundStyle(Tokens.text3)
                    Spacer(minLength: 4)
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.sf(10.5, weight: .semibold)).foregroundStyle(Tokens.text2)
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        // Monospaced digits so the minute ticking over doesn't shift
                        // the row's width.
                        .font(.sf(10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Tokens.text3)
                }
                weatherLine
            }
            .lineLimit(1)
        }
    }

    /// Conditions, tucked under the clock it belongs with — glyph and temperature,
    /// nothing else. Sized a step below the date row and in the dimmest text
    /// token, so it reads as an annotation to the time rather than a third
    /// competing element in a header that is already carrying two.
    ///
    /// Absent entirely when there is nothing to say (Location never granted, first
    /// fetch still in flight, offline). An empty weather slot would make the
    /// header jump by a line the moment it filled — better to have the row appear
    /// once and stay.
    @ViewBuilder private var weatherLine: some View {
        if let weather = utilities.weather {
            HStack(spacing: 3) {
                Image(systemName: weather.symbolName)
                    .font(.system(size: 9, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(weather.shortTemperature)
                    .font(.sf(9.5, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(Tokens.text3)
            .accessibilityElement(children: .combine)
        }
    }

    /// The one thing you want from a calendar ten minutes before a meeting: the
    /// link. Appears only inside that window (and five minutes past the start,
    /// for the meeting you are already late to), so the card is unchanged the
    /// rest of the day.
    ///
    /// Full width and tinted, unlike every other control in this pane: it is the
    /// single most time-critical action the notch offers, and a quiet chip in a
    /// row of quiet chips would lose to the clock beside it.
    @ViewBuilder private var joinChip: some View {
        TimelineView(.everyMinute) { context in
            if let meeting = utilities.imminentMeeting(now: context.date) {
                Button {
                    NSWorkspace.shared.open(meeting.link.url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: meeting.link.service.symbolName)
                            .font(.system(size: 10, weight: .bold))
                        Text(L("utilities.join", meeting.link.service.displayName))
                            .font(.sf(11, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(meeting.event.startDate.formatted(date: .omitted, time: .shortened))
                            .font(.sf(10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Tokens.text3)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.green)
                .background(Color.green.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityLabel(L("utilities.join", meeting.link.service.displayName))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var eventRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Not `eventIdentifier`: every occurrence of a recurring event shares
            // it, and duplicate ids make SwiftUI drop or repeat rows.
            ForEach(visibleDayEvents, id: \.self) { event in
                HStack(spacing: 7) {
                    Circle().fill(Tokens.text3).frame(width: 5, height: 5)
                    VStack(alignment: .leading, spacing: 1) {
                        // A shared calendar's private event arrives with no title.
                        Text(event.title?.isEmpty == false ? event.title! : "Busy")
                            .font(.sf(11.5, weight: .semibold)).lineLimit(1)
                        Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                            .font(.sf(9.5, weight: .regular)).foregroundStyle(Tokens.text3)
                    }
                    Spacer()
                }
            }
        }
    }
}
