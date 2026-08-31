import XCTest
@testable import NotchCapabilities

final class MeetingLinkTests: XCTestCase {
    // MARK: - Recognising services

    func testFindsZoomInTheLocationField() {
        let link = MeetingLink.detect(url: nil,
                                      location: "https://us02web.zoom.us/j/8412345678?pwd=abc",
                                      notes: nil)
        XCTAssertEqual(link?.service, .zoom)
    }

    func testFindsMeetInTheURLField() {
        let link = MeetingLink.detect(url: "https://meet.google.com/abc-defg-hij",
                                      location: "Conference room 2", notes: nil)
        XCTAssertEqual(link?.service, .meet)
    }

    func testFindsTeamsBuriedInInvitationBoilerplate() {
        let notes = """
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join on your computer, mobile app or room device
        Click here to join the meeting <https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0>
        Learn more <https://aka.ms/JoinTeamsMeeting> | Meeting options <https://teams.microsoft.com/meetingOptions/>
        """
        let link = MeetingLink.detect(url: nil, location: nil, notes: notes)
        XCTAssertEqual(link?.service, .teams)
        XCTAssertTrue(link?.url.absoluteString.contains("meetup-join") ?? false)
    }

    func testFindsWebexAndFaceTime() {
        XCTAssertEqual(MeetingLink.detect(url: "https://acme.webex.com/meet/priya",
                                          location: nil, notes: nil)?.service, .webex)
        XCTAssertEqual(MeetingLink.detect(url: "https://facetime.apple.com/join#v=1&p=abc",
                                          location: nil, notes: nil)?.service, .facetime)
    }

    // MARK: - Not everything that says "zoom" is a call

    func testZoomMarketingPagesAreNotMeetings() {
        XCTAssertNil(MeetingLink.detect(url: "https://zoom.us/pricing", location: nil, notes: nil))
        XCTAssertNil(MeetingLink.detect(url: nil, location: nil,
                                        notes: "We use https://zoom.us for standups"))
    }

    func testTeamsMarketingLinksAreNotMeetings() {
        XCTAssertNil(MeetingLink.detect(url: nil, location: nil,
                                        notes: "Learn more at https://teams.microsoft.com/downloads"))
    }

    func testAnAgendaDocIsNotAMeeting() {
        let notes = "Agenda: https://docs.google.com/document/d/abc123/edit"
        XCTAssertNil(MeetingLink.detect(url: nil, location: nil, notes: notes))
    }

    func testTextWithNoLinksAtAll() {
        XCTAssertNil(MeetingLink.detect(url: nil, location: "Kitchen", notes: "Bring the laptop"))
        XCTAssertNil(MeetingLink.detect(url: nil, location: nil, notes: nil))
    }

    // MARK: - Precedence

    func testAKnownServiceBeatsAGenericJoinLink() {
        let notes = """
        Backup line: https://example.com/join/room-4
        Primary: https://meet.google.com/abc-defg-hij
        """
        XCTAssertEqual(MeetingLink.detect(url: nil, location: nil, notes: notes)?.service, .meet)
    }

    func testAGenericJoinLinkIsUsedWhenNothingBetterExists() {
        let link = MeetingLink.detect(url: nil, location: nil,
                                      notes: "Dial in at https://whereby.com/join/design-sync")
        XCTAssertEqual(link?.service, .generic)
    }

    func testTheURLFieldWinsOverTheNotes() {
        let link = MeetingLink.detect(url: "https://meet.google.com/aaa-bbbb-ccc",
                                      location: nil,
                                      notes: "old link https://us02web.zoom.us/j/999")
        XCTAssertEqual(link?.service, .meet, "the dedicated field is the authoritative one")
    }

    // MARK: - When the chip shows

    func testTheChipAppearsTenMinutesAheadAndNotBefore() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(MeetingWindow.isImminent(start: now.addingTimeInterval(11 * 60), now: now))
        XCTAssertTrue(MeetingWindow.isImminent(start: now.addingTimeInterval(9 * 60), now: now))
        XCTAssertTrue(MeetingWindow.isImminent(start: now, now: now))
    }

    func testItSurvivesFiveMinutesPastTheStartForTheMeetingYoureLateTo() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(MeetingWindow.isImminent(start: now.addingTimeInterval(-4 * 60), now: now))
        XCTAssertFalse(MeetingWindow.isImminent(start: now.addingTimeInterval(-6 * 60), now: now))
    }
}
