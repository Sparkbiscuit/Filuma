//
//  FilumaUITests.swift
//  FilumaUITests
//
//  Created by Nicholas Christoforakis on 8/14/24.
//

import XCTest

final class FilumaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testFreshLaunchCompletesOnboarding() throws {
        let app = launchApp()

        let welcomeTitle = app.staticTexts["You add the task. Filuma finds the time."]
        let customize = app.buttons["onboarding.customize"]
        let startWithDefaults = app.buttons["onboarding.startWithDefaults"]
        assertVisible(welcomeTitle)
        assertVisible(element(labeled: "Step 1 of 3", in: app))
        assertVisible(customize)
        assertVisible(startWithDefaults)

        customize.tap()
        assertOnboardingDayStage(in: app)
        assertVisible(element(labeled: "Step 2 of 3", in: app))

        // Back is stage-aware: from the day editor it returns to the authored
        // welcome choice without completing onboarding or discarding the flow.
        let back = app.buttons["onboarding.back"]
        assertVisible(back)
        back.tap()
        assertVisible(welcomeTitle)
        assertVisible(customize)

        customize.tap()
        assertOnboardingDayStage(in: app)
        app.buttons["onboarding.continue"].tap()
        assertOnboardingBlocksStage(in: app)
        assertVisible(element(labeled: "Step 3 of 3", in: app))

        // From the block editor, Back must return one stage rather than all the
        // way to the welcome choice. This guards the backward stage ordering.
        assertVisible(back)
        back.tap()
        assertOnboardingDayStage(in: app)

        app.buttons["onboarding.continue"].tap()
        assertOnboardingBlocksStage(in: app)
        let finish = app.buttons["onboarding.finish"]
        assertVisible(finish)
        finish.tap()

        assertVisible(app.staticTexts["Your Tasks"])
        assertVisible(app.staticTexts["tasks.empty.firstTitle"])
        assertVisible(app.buttons["tasks.empty.addFirst"])
        XCTAssertTrue(app.buttons["Tasks"].isSelected)
    }

    func testFreshLaunchCanUseRecommendedDefaults() throws {
        let app = launchApp()

        assertVisible(app.staticTexts["You add the task. Filuma finds the time."])
        let startWithDefaults = app.buttons["onboarding.startWithDefaults"]
        assertVisible(startWithDefaults)
        XCTAssertTrue(startWithDefaults.isHittable)
        startWithDefaults.tap()

        assertVisible(app.staticTexts["Your Tasks"])
        assertVisible(app.staticTexts["tasks.empty.firstTitle"])
        assertVisible(app.buttons["tasks.empty.addFirst"])
        XCTAssertTrue(app.buttons["Tasks"].isSelected)
    }

    func testOnboardingControlsRemainReachableAtAccessibility5() throws {
        let app = launchApp(accessibilityText: true)

        let welcomeTitle = app.staticTexts["You add the task. Filuma finds the time."]
        let customize = app.buttons["onboarding.customize"]
        let startWithDefaults = app.buttons["onboarding.startWithDefaults"]
        assertVisible(welcomeTitle)
        assertOnboardingAction(customize)
        assertOnboardingAction(startWithDefaults)

        customize.tap()

        let dayTitle = app.staticTexts["onboarding.day.title"]
        let wakeTime = app.descendants(matching: .any)["onboarding.wakeTime"]
        let sleepTime = app.descendants(matching: .any)["onboarding.sleepTime"]
        let dayContinue = app.buttons["onboarding.continue"]
        let dayBack = app.buttons["onboarding.back"]
        for element in [dayTitle, wakeTime, sleepTime, dayContinue, dayBack] {
            assertVisible(element)
        }
        assertOnboardingAction(dayContinue)
        assertOnboardingAction(dayBack)
        let dayContinueFrame = dayContinue.frame
        let dayBackFrame = dayBack.frame
        assertOnboardingContentReachable(dayTitle, above: dayContinue, in: app)
        for control in [wakeTime, sleepTime] {
            assertOnboardingEditableControl(control, above: dayContinue, in: app)
        }
        assertFixedOnboardingAction(dayContinue, matches: dayContinueFrame)
        assertFixedOnboardingAction(dayBack, matches: dayBackFrame)

        dayContinue.tap()

        let blocksTitle = app.staticTexts["onboarding.blocks.title"]
        let adjustmentButtons = [
            "onboarding.minimumBlock.decrement",
            "onboarding.minimumBlock.increment",
            "onboarding.maximumBlock.decrement",
            "onboarding.maximumBlock.increment",
            "onboarding.deadlineBuffer.decrement",
            "onboarding.deadlineBuffer.increment"
        ].map { app.buttons[$0] }
        let finish = app.buttons["onboarding.finish"]
        let blocksBack = app.buttons["onboarding.back"]
        for element in [blocksTitle, finish, blocksBack] + adjustmentButtons {
            assertVisible(element)
        }
        assertOnboardingAction(finish)
        assertOnboardingAction(blocksBack)
        let finishFrame = finish.frame
        let blocksBackFrame = blocksBack.frame
        assertOnboardingContentReachable(blocksTitle, above: finish, in: app)
        for control in adjustmentButtons {
            assertOnboardingEditableControl(control, above: finish, in: app)
        }
        assertFixedOnboardingAction(finish, matches: finishFrame)
        assertFixedOnboardingAction(blocksBack, matches: blocksBackFrame)
    }

    func testSkipOnboardingNavigatesTabsAndInspectsCaptureOptions() throws {
        let app = launchApp(skipOnboarding: true)

        assertVisible(app.staticTexts["Your Tasks"])
        assertVisible(app.staticTexts["tasks.empty.firstTitle"])
        let firstTaskButton = app.buttons["tasks.empty.addFirst"]
        assertVisible(firstTaskButton)
        XCTAssertTrue(firstTaskButton.isHittable)
        firstTaskButton.tap()

        let firstCaptureTitleField = app.textFields["capture.taskTitleField"]
        assertVisible(firstCaptureTitleField)
        app.buttons["capture.close"].tap()
        XCTAssertTrue(firstCaptureTitleField.waitForNonExistence(timeout: 3))

        visitTab("Schedule", showing: "Schedule", in: app)
        visitTab("Weave", showing: "Your Weave", in: app)
        visitTab("Settings", showing: "Settings", in: app)
        visitTab("Tasks", showing: "Your Tasks", in: app)

        let captureButton = app.buttons["Capture a task"]
        assertVisible(captureButton)
        captureButton.tap()

        let titleField = app.textFields["capture.taskTitleField"]
        assertVisible(titleField)
        dismissKeyboardIfNeeded(in: app)

        let primaryAction = app.buttons["capture.primaryAction"]
        let schedulingOptions = app.buttons["capture.moreSchedulingOptions"]
        assertCaptureControlReachable(
            schedulingOptions,
            above: primaryAction,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        schedulingOptions.tap()
        waitForValue("Expanded", on: schedulingOptions)

        let oneOff = app.buttons["capture.repeat.oneOff"]
        let weekly = app.buttons["capture.repeat.weekly"]
        let soon = app.buttons["capture.start.soon"]
        let pickATime = app.buttons["capture.start.custom"]
        for option in [oneOff, weekly, soon, pickATime] {
            materializeSheetControl(option, in: app, surface: "Capture")
            assertCaptureControlReachable(
                option,
                above: primaryAction,
                in: app,
                minimumVisibleHeight: 44,
                requiresHitTesting: true
            )
        }
        XCTAssertEqual(oneOff.label, "One-off")
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(soon.label, "Soon")
        XCTAssertEqual(pickATime.label, "Pick a time")

        app.buttons["capture.close"].tap()
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 3))
        assertVisible(app.staticTexts["Your Tasks"])
    }

    func testCaptureCreatesExactTaskWithKeyboardVisibleAndReturnsToTasks() throws {
        let app = launchApp(skipOnboarding: true)

        assertVisible(app.staticTexts["Your Tasks"])
        openCapture(in: app)

        let captureTitle = app.staticTexts["capture.title"]
        let close = app.buttons["capture.close"]
        let bulk = app.buttons["capture.bulk"]
        let taskMode = app.buttons["capture.mode.task"]
        let reminderMode = app.buttons["capture.mode.reminder"]
        let titleField = app.textFields["capture.taskTitleField"]
        let voiceInput = app.buttons["capture.voiceInputButton"]
        let primaryAction = app.buttons["capture.primaryAction"]

        for element in [
            captureTitle,
            close,
            bulk,
            taskMode,
            reminderMode,
            titleField,
            voiceInput,
            primaryAction
        ] {
            assertVisible(element)
        }
        XCTAssertTrue(taskMode.isSelected, "Capture should open in Task mode.")
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertGreaterThanOrEqual(bulk.frame.height, 44)
        XCTAssertGreaterThanOrEqual(voiceInput.frame.height, 44)

        // Whitespace is not a task. Exercise that validation in a clean sheet,
        // then close and reopen so the happy path can assert an exact title.
        titleField.tap()
        titleField.typeText("   ")
        XCTAssertFalse(
            primaryAction.isEnabled,
            "Whitespace-only input must not enable the capture action."
        )
        XCTAssertFalse(app.descendants(matching: .any)["capture.issue"].exists)
        XCTAssertTrue(close.isHittable, "Close must remain available while the keyboard is visible.")
        close.tap()
        XCTAssertTrue(captureTitle.waitForNonExistence(timeout: 3))

        openCapture(in: app)

        let exactTitle = "Build the beta launch checklist"
        let exactFirstStep = "Open the release notes document"
        let reopenedTitle = app.staticTexts["capture.title"]
        let reopenedTitleField = app.textFields["capture.taskTitleField"]
        let reopenedPrimaryAction = app.buttons["capture.primaryAction"]
        assertVisible(reopenedTitleField)
        reopenedTitleField.tap()
        reopenedTitleField.typeText(exactTitle)
        XCTAssertEqual(reopenedTitleField.value as? String, exactTitle)

        let keyboard = app.keyboards.firstMatch
        assertVisible(keyboard)
        assertCapturePrimaryAction(
            reopenedPrimaryAction,
            above: keyboard,
            in: app
        )

        let firstStep = app.textFields["capture.firstStepField"]
        assertVisible(firstStep)
        assertCaptureControlReachable(
            firstStep,
            above: reopenedPrimaryAction,
            in: app,
            minimumVisibleHeight: 20,
            requiresHitTesting: true
        )
        firstStep.tap()
        firstStep.typeText(exactFirstStep)
        XCTAssertEqual(firstStep.value as? String, exactFirstStep)

        dismissKeyboardIfNeeded(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let workContext = app.buttons["capture.context.work"]
        let sixtyMinutes = app.buttons["capture.effort.60"]
        for choice in [workContext, sixtyMinutes] {
            assertCaptureControlReachable(
                choice,
                above: reopenedPrimaryAction,
                in: app,
                minimumVisibleHeight: 44,
                requiresHitTesting: true
            )
            choice.tap()
            assertSelected(choice)
        }
        XCTAssertFalse(app.descendants(matching: .any)["capture.issue"].exists)

        assertCapturePrimaryAction(reopenedPrimaryAction, in: app)
        reopenedPrimaryAction.tap()
        assertCaptureHandoff(
            taskTitle: exactTitle,
            captureTitle: reopenedTitle,
            in: app
        )
    }

    func testCaptureControlsRemainReachableAtAccessibility5() throws {
        let app = launchApp(skipOnboarding: true, accessibilityText: true)
        openCapture(in: app)

        let captureTitle = app.staticTexts["capture.title"]
        let close = app.buttons["capture.close"]
        let bulk = app.buttons["capture.bulk"]
        let taskMode = app.buttons["capture.mode.task"]
        let reminderMode = app.buttons["capture.mode.reminder"]
        let titleField = app.textFields["capture.taskTitleField"]
        let primaryAction = app.buttons["capture.primaryAction"]

        assertVisible(captureTitle)
        for action in [close, bulk, taskMode, reminderMode] {
            assertVisible(action)
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(
                action.frame.height,
                44,
                "Expected \(action.identifier) to preserve a 44pt touch target at Accessibility 5."
            )
        }
        XCTAssertTrue(taskMode.isSelected)
        XCTAssertFalse(
            close.frame.intersects(captureTitle.frame),
            "The Capture heading and Close action must remain spatially distinct."
        )
        XCTAssertFalse(
            bulk.frame.intersects(captureTitle.frame),
            "The Capture heading and Bulk action must remain spatially distinct."
        )

        titleField.tap()
        titleField.typeText("Accessibility capture check")
        dismissKeyboardIfNeeded(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        assertCapturePrimaryAction(primaryAction, in: app)
        let fixedTaskActionFrame = primaryAction.frame

        let taskControls: [XCUIElement] = [
            titleField,
            app.buttons["capture.voiceInputButton"],
            app.textFields["capture.firstStepField"],
            app.buttons["capture.context.school"],
            app.buttons["capture.context.work"],
            app.buttons["capture.context.personal"],
            app.descendants(matching: .any)["capture.deadline"],
            app.buttons["capture.effort.30"],
            app.buttons["capture.effort.60"],
            app.buttons["capture.effort.120"],
            app.buttons["capture.effort.custom"],
            app.buttons["capture.moreSchedulingOptions"]
        ]
        for control in taskControls {
            assertCaptureControlReachable(
                control,
                above: primaryAction,
                in: app,
                minimumVisibleHeight: 44,
                requiresHitTesting: true
            )
            XCTAssertGreaterThanOrEqual(
                control.frame.height,
                44,
                "Expected \(control.identifier) to preserve a 44pt touch target at Accessibility 5."
            )
            assertFixedCaptureAction(primaryAction, matches: fixedTaskActionFrame)
        }

        let customEffort = app.buttons["capture.effort.custom"]
        assertCaptureControlReachable(
            customEffort,
            above: primaryAction,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        customEffort.tap()
        assertSelected(customEffort)
        let schedulingOptions = app.buttons["capture.moreSchedulingOptions"]
        assertCaptureControlReachable(
            schedulingOptions,
            above: primaryAction,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        schedulingOptions.tap()
        waitForValue("Expanded", on: schedulingOptions)
        assertFixedCaptureAction(primaryAction, matches: fixedTaskActionFrame)

        assertCaptureControlReachable(
            reminderMode,
            above: primaryAction,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        reminderMode.tap()
        assertSelected(reminderMode)

        let reminderDate = app.descendants(matching: .any)["capture.reminderDate"]
        assertCaptureControlReachable(
            reminderDate,
            above: primaryAction,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        XCTAssertGreaterThanOrEqual(
            reminderDate.frame.height,
            44,
            "The reminder date editor must preserve a 44pt touch target at Accessibility 5."
        )
        assertFixedCaptureAction(primaryAction, matches: fixedTaskActionFrame)
        XCTAssertFalse(app.descendants(matching: .any)["capture.issue"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["capture.success"].exists)
    }

    func testBulkCaptureSchedulesTwoExactTasksAndReturnsToTasks() throws {
        let app = launchApp(skipOnboarding: true)
        openBulkCapture(in: app)

        let bulkTitle = app.staticTexts["bulk.title"]
        let back = app.buttons["bulk.back"]
        let readyCount = app.staticTexts["bulk.readyCount"]
        let firstTitleField = app.textFields["bulk.row.1.title"]
        let addRow = app.buttons["bulk.addRow"]
        let scheduleAll = app.buttons["bulk.scheduleAll"]
        for element in [bulkTitle, back, readyCount, firstTitleField, addRow, scheduleAll] {
            assertVisible(element)
        }
        XCTAssertEqual(bulkTitle.label, "A handful at once")
        XCTAssertEqual(readyCount.label, "0 ready")
        XCTAssertFalse(scheduleAll.isEnabled)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)

        let firstTitle = "Draft the launch announcement"
        let secondTitle = "Review subscription screenshots"
        firstTitleField.tap()
        firstTitleField.typeText(firstTitle)
        XCTAssertEqual(firstTitleField.value as? String, firstTitle)
        waitForLabel("1 ready", on: readyCount)

        let keyboard = app.keyboards.firstMatch
        assertVisible(keyboard)
        assertBulkAction(scheduleAll, above: keyboard, in: app)
        assertBulkAction(addRow, above: keyboard, in: app)
        addRow.tap()
        let secondTitleField = app.textFields["bulk.row.2.title"]
        assertVisible(secondTitleField)
        secondTitleField.tap()
        secondTitleField.typeText(secondTitle)
        XCTAssertEqual(secondTitleField.value as? String, secondTitle)
        waitForLabel("2 ready", on: readyCount)
        assertVisible(app.buttons["bulk.row.2.remove"])

        assertBulkAction(scheduleAll, above: keyboard, in: app)
        XCTAssertFalse(app.descendants(matching: .any)["bulk.issue"].exists)

        // The fixed Schedule action is deliberately used while the second
        // native field still owns the keyboard. A single tap must commit the
        // entire batch and replace editing with a factual durable receipt.
        scheduleAll.tap()

        let success = app.descendants(matching: .any)["bulk.success"]
        let finish = app.buttons["bulk.finish"]
        assertVisible(success)
        assertVisible(app.staticTexts["2 threads joined the plan"])
        assertBulkReceiptContainsExactTitle(firstTitle, in: app)
        assertBulkReceiptContainsExactTitle(secondTitle, in: app)
        XCTAssertFalse(app.descendants(matching: .any)["bulk.issue"].exists)
        XCTAssertTrue(scheduleAll.waitForNonExistence(timeout: 3))
        assertBulkAction(finish, in: app)
        XCTAssertEqual(finish.label, "Review 2 tasks")

        finish.tap()
        assertBulkHandoff(
            taskTitles: [firstTitle, secondTitle],
            bulkTitle: bulkTitle,
            in: app
        )
    }

    func testFreeTierBulkCaptureStopsAtThreeActiveTasks() throws {
        let app = launchApp(
            skipOnboarding: true,
            seedFreeBoundary: true,
            freeTier: true
        )
        openBulkCapture(in: app)

        let firstTitleField = app.textFields["bulk.row.1.title"]
        assertVisible(firstTitleField)
        firstTitleField.tap()
        firstTitleField.typeText("A third thread")

        app.buttons["bulk.addRow"].tap()
        let secondTitleField = app.textFields["bulk.row.2.title"]
        assertVisible(secondTitleField)
        secondTitleField.tap()
        secondTitleField.typeText("One over the free limit")

        app.buttons["bulk.scheduleAll"].tap()

        assertVisible(app.descendants(matching: .any)["pro.paywall"])
        assertVisible(app.buttons["pro.paywall.close"])
        XCTAssertFalse(app.descendants(matching: .any)["bulk.success"].exists)
    }

    func testBulkControlsRemainReachableAtAccessibility5() throws {
        let app = launchApp(skipOnboarding: true, accessibilityText: true)
        openBulkCapture(in: app)

        let bulkTitle = app.staticTexts["bulk.title"]
        let back = app.buttons["bulk.back"]
        let readyCount = app.staticTexts["bulk.readyCount"]
        let firstTitleField = app.textFields["bulk.row.1.title"]
        let context = app.buttons["bulk.row.1.context"]
        let effort = app.buttons["bulk.row.1.effort"]
        let deadline = app.descendants(matching: .any)["bulk.row.1.deadline"]
        let addRow = app.buttons["bulk.addRow"]
        let scheduleAll = app.buttons["bulk.scheduleAll"]
        for element in [
            bulkTitle,
            back,
            readyCount,
            firstTitleField,
            context,
            effort,
            deadline,
            addRow,
            scheduleAll
        ] {
            assertVisible(element)
        }
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)

        firstTitleField.tap()
        firstTitleField.typeText("Accessibility bulk task")
        waitForLabel("1 ready", on: readyCount)
        dismissKeyboardIfNeeded(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))

        assertBulkAction(scheduleAll, in: app)
        assertBulkAction(addRow, in: app)
        let fixedScheduleFrame = scheduleAll.frame
        let fixedAddFrame = addRow.frame
        XCTAssertTrue(
            !scheduleAll.frame.intersects(addRow.frame),
            "Accessibility 5 should lay out the Bulk actions without overlap. " +
                "Schedule=\(scheduleAll.frame), Add=\(addRow.frame)."
        )

        for control in [firstTitleField, context, effort, deadline] {
            assertBulkControlReachable(
                control,
                above: scheduleAll,
                in: app,
                minimumVisibleHeight: 44,
                requiresHitTesting: true
            )
            XCTAssertGreaterThanOrEqual(
                control.frame.height,
                44,
                "Expected \(control.identifier) to preserve a 44pt touch target at Accessibility 5."
            )
            assertFixedBulkAction(scheduleAll, matches: fixedScheduleFrame)
            assertFixedBulkAction(addRow, matches: fixedAddFrame)
        }

        addRow.tap()
        let secondTitleField = app.textFields["bulk.row.2.title"]
        materializeSheetControl(secondTitleField, in: app, surface: "Bulk")
        assertBulkControlReachable(
            secondTitleField,
            above: scheduleAll,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        XCTAssertGreaterThanOrEqual(secondTitleField.frame.height, 44)

        if app.keyboards.firstMatch.exists {
            assertBulkAction(scheduleAll, above: app.keyboards.firstMatch, in: app)
            assertBulkAction(addRow, above: app.keyboards.firstMatch, in: app)
        }
        dismissKeyboardIfNeeded(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        assertFixedBulkAction(scheduleAll, matches: fixedScheduleFrame)
        assertFixedBulkAction(addRow, matches: fixedAddFrame)

        let removeSecondRow = app.buttons["bulk.row.2.remove"]
        materializeSheetControl(removeSecondRow, in: app, surface: "Bulk")
        assertBulkControlReachable(
            removeSecondRow,
            above: scheduleAll,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        XCTAssertGreaterThanOrEqual(removeSecondRow.frame.height, 44)
        removeSecondRow.tap()

        XCTAssertTrue(secondTitleField.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bulk.row.1.remove"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(readyCount.label, "1 ready")
        assertBulkAction(scheduleAll, in: app)
        assertBulkAction(addRow, in: app)
        assertFixedBulkAction(scheduleAll, matches: fixedScheduleFrame)
        assertFixedBulkAction(addRow, matches: fixedAddFrame)
        XCTAssertFalse(app.descendants(matching: .any)["bulk.issue"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["bulk.success"].exists)
    }

    func testSettingsToggleExposesSwitchSemantics() throws {
        let app = launchApp(skipOnboarding: true)
        visitTab("Settings", showing: "Settings", in: app)

        let blockNudges = app.switches["Block start nudges"]
        scrollToHittable(blockNudges, in: app)
        assertVisible(blockNudges)
        XCTAssertTrue(blockNudges.isHittable)
        XCTAssertTrue(
            ["0", "1"].contains(blockNudges.value as? String),
            "Expected a native on/off accessibility value from the custom Toggle style."
        )
    }

    func testSettingsControlsRemainReachableAtAccessibility5() throws {
        let app = launchApp(skipOnboarding: true, accessibilityText: true)
        dismissNotificationPermissionIfPresent(in: app)
        visitTab("Settings", showing: "Settings", in: app)

        let hearthTitle = app.staticTexts["settings.hearth.title"]
        assertVisible(hearthTitle)

        let hearthSwatches = ["ember", "indigo", "sage", "violet"].map {
            app.buttons["settings.hearth.\($0)"]
        }
        for swatch in hearthSwatches {
            assertSettingsControlReachable(swatch, in: app)
        }
        XCTAssertEqual(
            hearthSwatches.filter(\.isSelected).count,
            1,
            "Expected the Hearth panel to expose exactly one selected flame."
        )

        let wakeTime = app.datePickers["Wake time"]
        assertSettingsControlReachable(wakeTime, in: app)

        let dailyFocusLimit = app.steppers["Daily focus limit"]
        assertSettingsControlReachable(dailyFocusLimit, in: app)
        XCTAssertFalse(
            (dailyFocusLimit.value as? String)?.isEmpty ?? true,
            "Expected Daily focus limit to expose its native Stepper value."
        )

        let blockNudges = app.switches["Block start nudges"]
        assertSettingsControlReachable(blockNudges, in: app)
        XCTAssertTrue(
            ["0", "1"].contains(blockNudges.value as? String),
            "Expected Block start nudges to retain native switch semantics at Accessibility 5."
        )
    }

    func testBlockedTimeEditorControlsRemainReachableAtAccessibility5() throws {
        let app = launchApp(skipOnboarding: true, accessibilityText: true)
        dismissNotificationPermissionIfPresent(in: app)
        visitTab("Settings", showing: "Settings", in: app)

        let blockedTimes = app.buttons["Blocked Times"]
        assertVisible(blockedTimes)
        scrollSettingsRouteToHittable(blockedTimes, in: app)
        XCTAssertGreaterThanOrEqual(blockedTimes.frame.height, 44)
        blockedTimes.tap()

        assertVisible(app.staticTexts["Blocked Times"])
        let addBlockedTime = app.buttons["blockedTime.add"]
        assertVisible(addBlockedTime)
        scrollToHittable(addBlockedTime, in: app)
        assertBlockedTimeToolbarControlReachable(addBlockedTime, in: app)
        addBlockedTime.tap()

        assertVisible(app.staticTexts["Blocked Time"])
        let save = app.buttons["blockedTime.save"]
        assertVisible(save)
        assertBlockedTimeToolbarControlReachable(save, in: app)
        let fixedSaveFrame = waitForStableFrame(of: save)

        let name = app.textFields["blockedTime.name"]
        let starts = app.descendants(matching: .any)["blockedTime.starts"]
        let ends = app.descendants(matching: .any)["blockedTime.ends"]
        let weekdays = (1...7).map { app.buttons["blockedTime.weekday.\($0)"] }

        assertBlockedTimeEditorControlReachable(name, in: app)
        XCTAssertEqual(name.elementType, .textField)

        for weekday in weekdays {
            assertBlockedTimeEditorControlReachable(weekday, in: app)
            XCTAssertEqual(weekday.elementType, .button)
        }
        for firstIndex in weekdays.indices {
            for secondIndex in weekdays.indices where secondIndex > firstIndex {
                XCTAssertFalse(
                    weekdays[firstIndex].frame.intersects(weekdays[secondIndex].frame),
                    "Weekday controls must not overlap at Accessibility 5. " +
                        "\(weekdays[firstIndex].identifier)=\(weekdays[firstIndex].frame), " +
                        "\(weekdays[secondIndex].identifier)=\(weekdays[secondIndex].frame)."
                )
            }
        }

        for timeControl in [starts, ends] {
            assertBlockedTimeEditorControlReachable(timeControl, in: app)
            XCTAssertEqual(timeControl.elementType, .datePicker)
        }

        assertBlockedTimeToolbarControlReachable(save, in: app)
        let finalSaveFrame = waitForStableFrame(of: save)
        XCTAssertEqual(finalSaveFrame.minX, fixedSaveFrame.minX, accuracy: 2)
        XCTAssertEqual(finalSaveFrame.minY, fixedSaveFrame.minY, accuracy: 2)
        XCTAssertEqual(finalSaveFrame.width, fixedSaveFrame.width, accuracy: 2)
        XCTAssertEqual(finalSaveFrame.height, fixedSaveFrame.height, accuracy: 2)
    }

    func testBlockedTimeDirtyCancelKeepsThenDiscardsDraft() throws {
        let app = launchApp(skipOnboarding: true)
        dismissNotificationPermissionIfPresent(in: app)
        visitTab("Settings", showing: "Settings", in: app)

        let blockedTimes = app.buttons["Blocked Times"]
        assertVisible(blockedTimes)
        scrollSettingsRouteToHittable(blockedTimes, in: app)
        blockedTimes.tap()

        let addBlockedTime = app.buttons["blockedTime.add"]
        assertVisible(addBlockedTime)
        scrollToHittable(addBlockedTime, in: app)
        addBlockedTime.tap()

        let name = app.textFields["blockedTime.name"]
        assertVisible(name)
        name.tap()
        name.typeText("Deep work")

        let cancel = app.buttons["Cancel"].firstMatch
        assertVisible(cancel)
        cancel.tap()

        let discardAlert = app.alerts.firstMatch
        assertVisible(discardAlert.staticTexts["Discard blocked time draft?"])
        let keepEditing = discardAlert.buttons["Keep Editing"]
        let discard = discardAlert.buttons["Discard Changes"]
        assertVisible(keepEditing)
        assertVisible(discard)
        keepEditing.tap()

        assertVisible(name)
        XCTAssertEqual(name.value as? String, "Deep work")

        cancel.tap()
        assertVisible(discard)
        discard.tap()
        XCTAssertTrue(
            app.staticTexts["Blocked Time"].waitForNonExistence(timeout: 5),
            "Discard Changes must close the blocked-time editor."
        )
        assertVisible(app.staticTexts["Blocked Times"])
    }

    func testScheduleWeekNavigationPagesAndHandsOffFarFutureDayAtAccessibility5() throws {
        let app = launchApp(
            skipOnboarding: true,
            accessibilityText: true,
            seedSchedule: true
        )
        dismissNotificationPermissionIfPresent(in: app)
        visitTab("Schedule", showing: "Schedule", in: app)

        let weekMode = app.buttons["schedule.mode.week"]
        assertVisible(weekMode)
        weekMode.tap()

        let weekRange = app.staticTexts["schedule.weekRange"]
        let previousWeek = app.buttons["schedule.previousWeek"]
        let today = app.buttons["schedule.today"]
        let nextWeek = app.buttons["schedule.nextWeek"]
        let weekGrid = app.scrollViews["schedule.weekGrid"]
        for control in [previousWeek, today, nextWeek] {
            assertScheduleNavigationControl(control, in: app)
        }
        assertVisible(weekRange)
        assertVisible(weekGrid)
        let currentWeekLabel = weekRange.label
        XCTAssertFalse(currentWeekLabel.isEmpty)

        nextWeek.tap()
        waitForLabelChange(from: currentWeekLabel, on: weekRange)
        let nextWeekLabel = weekRange.label
        previousWeek.tap()
        waitForLabel(currentWeekLabel, on: weekRange)

        previousWeek.tap()
        waitForLabelChange(from: currentWeekLabel, on: weekRange)
        XCTAssertNotEqual(weekRange.label, nextWeekLabel)
        today.tap()
        waitForLabel(currentWeekLabel, on: weekRange)

        // Six weeks is deliberately beyond the original 30-day Day-strip
        // horizon. Each transition must author a new, observable week rather
        // than accumulating taps against an in-flight animation.
        for _ in 0..<6 {
            let priorLabel = weekRange.label
            nextWeek.tap()
            waitForLabelChange(from: priorLabel, on: weekRange)
        }

        let farFutureItem = app.buttons["Far future schedule fixture"]
        assertScheduleWeekItemReachable(farFutureItem, in: weekGrid, app: app)
        let weekdayHeaders = scheduleWeekdayHeaders(in: app)
        XCTAssertEqual(weekdayHeaders.count, 7)
        guard let farFutureHeader = weekdayHeaders.first(where: {
            $0.frame.minX <= farFutureItem.frame.midX && farFutureItem.frame.midX <= $0.frame.maxX
        }) else {
            XCTFail(
                "Expected Far future schedule fixture to align with a dated week header. " +
                    "Item=\(farFutureItem.frame), headers=\(weekdayHeaders.map { "\($0.identifier)=\($0.frame)" })."
            )
            return
        }
        XCTAssertGreaterThanOrEqual(farFutureHeader.frame.width, 44)
        XCTAssertGreaterThanOrEqual(farFutureHeader.frame.height, 44)
        let expectedDayIdentifier = farFutureHeader.identifier.replacingOccurrences(
            of: "schedule.weekday.",
            with: "schedule.day."
        )

        farFutureItem.tap()
        let selectedFarFutureDay = app.buttons[expectedDayIdentifier]
        assertVisible(selectedFarFutureDay)
        XCTAssertTrue(
            selectedFarFutureDay.isSelected,
            "Expected the far-future week item to hand off to its matching selected Day pill."
        )
        XCTAssertTrue(previousWeek.waitForNonExistence(timeout: 3))
        let farFutureDayRow = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label CONTAINS %@",
                "Far future schedule fixture"
            ))
            .firstMatch
        assertVisible(farFutureDayRow)

        weekMode.tap()
        assertVisible(today)
        today.tap()
        waitForLabel(currentWeekLabel, on: weekRange)
    }

    func testScheduleWeekShowsEarlyLateAndOvernightFixtures() throws {
        let app = launchApp(skipOnboarding: true, seedSchedule: true)
        dismissNotificationPermissionIfPresent(in: app)
        visitTab("Schedule", showing: "Schedule", in: app)
        app.buttons["schedule.mode.week"].tap()

        let weekGrid = app.scrollViews["schedule.weekGrid"]
        assertVisible(weekGrid)
        let weekdayHeaders = scheduleWeekdayHeaders(in: app)
        XCTAssertEqual(weekdayHeaders.count, 7)

        let earlyItems = app.buttons
            .matching(NSPredicate(format: "label == %@", "Early schedule fixture"))
            .allElementsBoundByIndex
        let lateItems = app.buttons
            .matching(NSPredicate(format: "label == %@", "Late schedule fixture"))
            .allElementsBoundByIndex
        let overnightItems = app.buttons
            .matching(NSPredicate(format: "label == %@", "Overnight schedule fixture"))
            .allElementsBoundByIndex
        let overnightItemsByColumn = overnightItems.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(earlyItems.count, 1)
        XCTAssertEqual(lateItems.count, 1)
        XCTAssertEqual(
            overnightItems.count,
            2,
            "Expected a cross-midnight event to render once in each overlapping calendar-day column."
        )
        guard let earlyItem = earlyItems.first,
              let lateItem = lateItems.first,
              overnightItems.count == 2,
              weekdayHeaders.count == 7 else {
            return
        }

        let initialEarlyFrame = earlyItem.frame
        let initialLateFrame = lateItem.frame
        let initialOvernightFrames = overnightItemsByColumn.map(\.frame)
        XCTAssertLessThan(
            initialEarlyFrame.minY,
            initialLateFrame.minY,
            "The early fixture must render above the late fixture on the truthful week axis."
        )
        XCTAssertGreaterThan(
            initialOvernightFrames[0].minY,
            initialOvernightFrames[1].minY,
            "The pre-midnight overnight fragment must render below its next-day after-midnight fragment."
        )

        let expectedHeaderIndexes = [
            (element: earlyItem, headerIndex: 1, name: "early Tuesday"),
            (element: lateItem, headerIndex: 3, name: "late Thursday"),
            (element: overnightItemsByColumn[0], headerIndex: 4, name: "overnight Friday"),
            (element: overnightItemsByColumn[1], headerIndex: 5, name: "overnight Saturday")
        ]
        for expectation in expectedHeaderIndexes {
            let header = weekdayHeaders[expectation.headerIndex]
            XCTAssertGreaterThanOrEqual(
                expectation.element.frame.midX,
                header.frame.minX,
                "Expected \(expectation.name) fixture inside \(header.identifier)."
            )
            XCTAssertLessThanOrEqual(
                expectation.element.frame.midX,
                header.frame.maxX,
                "Expected \(expectation.name) fixture inside \(header.identifier)."
            )
            assertScheduleWeekItemReachable(
                expectation.element,
                in: weekGrid,
                app: app,
                requiresHitTesting: false
            )
        }

        let afterMidnightFragment = overnightItemsByColumn[1]
        assertScheduleWeekItemReachable(afterMidnightFragment, in: weekGrid, app: app)
        let saturdayDayIdentifier = weekdayHeaders[5].identifier.replacingOccurrences(
            of: "schedule.weekday.",
            with: "schedule.day."
        )
        afterMidnightFragment.tap()

        let selectedSaturday = app.buttons[saturdayDayIdentifier]
        assertVisible(selectedSaturday)
        XCTAssertTrue(
            selectedSaturday.isSelected,
            "Expected the after-midnight week fragment to open its Saturday calendar day."
        )
        XCTAssertTrue(app.buttons["schedule.mode.day"].isSelected)
        let continuedOvernight = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "Overnight schedule fixture",
                "Continued from yesterday"
            ))
            .firstMatch
        assertVisible(continuedOvernight)
        XCTAssertTrue(
            continuedOvernight.label.contains("Continued from yesterday"),
            "Expected the Day row to tell the truth about its prior-day continuation."
        )
    }

    func testTaskEditSavesChangesAndReturnsToUpdatedTask() throws {
        let taskTitle = "Book dentist appointment"
        let app = launchApp(skipOnboarding: true, seedLibrary: true)
        dismissNotificationPermissionIfPresent(in: app)
        openTaskEditor(for: taskTitle, in: app)

        let editorTitle = app.staticTexts["taskEdit.title"]
        let titleField = app.textFields["taskEdit.titleField"]
        let firstStepField = app.textFields["taskEdit.firstStepField"]
        let personal = app.buttons["taskEdit.context.personal"]
        let work = app.buttons["taskEdit.context.work"]
        let deadline = app.datePickers["taskEdit.deadline"]
        let effort = app.steppers["taskEdit.effort"]
        let save = app.buttons["taskEdit.save"]

        XCTAssertEqual(editorTitle.label, "Edit task")
        XCTAssertEqual(titleField.value as? String, taskTitle)
        XCTAssertEqual(firstStepField.value as? String, "Find the office number")
        XCTAssertTrue(personal.isSelected)
        XCTAssertEqual(effort.value as? String, "30m")
        XCTAssertFalse((deadline.value as? String)?.isEmpty ?? true)
        XCTAssertTrue(save.isEnabled)

        work.tap()
        assertSelected(work)
        save.tap()

        XCTAssertTrue(
            editorTitle.waitForNonExistence(timeout: 5),
            "Expected a valid Task Edit save to dismiss the sheet."
        )
        assertVisible(app.staticTexts["Your Tasks"])
        XCTAssertTrue(app.buttons["Tasks"].isSelected)
        let summary = taskSummary(named: taskTitle, in: app)
        assertVisible(summary)

        // Reopening the same durable task distinguishes a real save from a
        // merely optimistic sheet dismissal.
        openTaskEditor(for: taskTitle, in: app)
        let reopenedWork = app.buttons["taskEdit.context.work"]
        assertVisible(reopenedWork)
        XCTAssertTrue(reopenedWork.isSelected)
        XCTAssertFalse(app.buttons["taskEdit.context.personal"].isSelected)
        app.buttons["taskEdit.cancel"].tap()
        XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 3))
    }

    func testTaskEditDirtyCancelKeepsThenDiscardsDraft() throws {
        let taskTitle = "Book dentist appointment"
        let app = launchApp(skipOnboarding: true, seedLibrary: true)
        dismissNotificationPermissionIfPresent(in: app)
        openTaskEditor(for: taskTitle, in: app)

        let editorTitle = app.staticTexts["taskEdit.title"]
        let work = app.buttons["taskEdit.context.work"]
        let cancel = app.buttons["taskEdit.cancel"]
        work.tap()
        assertSelected(work)
        cancel.tap()

        assertVisible(app.staticTexts["Discard unsaved changes?"])
        assertVisible(app.staticTexts[
            "Your latest edits have not been saved. The task will keep its last saved details."
        ])
        // System alerts already provide unique native button semantics. Adding
        // identifiers to the declarative alert actions creates duplicate AX
        // wrapper/leaf Buttons, so select the visible alert actions by label.
        let discardAlert = app.alerts.firstMatch
        let keepEditing = discardAlert.buttons["Keep Editing"]
        let discard = discardAlert.buttons["Discard Changes"]
        assertVisible(keepEditing)
        assertVisible(discard)
        keepEditing.tap()

        XCTAssertTrue(keepEditing.waitForNonExistence(timeout: 3))
        assertVisible(editorTitle)
        XCTAssertTrue(work.isSelected, "Keep Editing must preserve the unsaved draft.")

        cancel.tap()
        assertVisible(discard)
        discard.tap()
        XCTAssertTrue(
            editorTitle.waitForNonExistence(timeout: 5),
            "Discard Changes must close the editor."
        )
        assertVisible(taskSummary(named: taskTitle, in: app))

        // Discard must leave the persisted model untouched, not just restore
        // the visible summary text.
        openTaskEditor(for: taskTitle, in: app)
        let reopenedPersonal = app.buttons["taskEdit.context.personal"]
        assertVisible(reopenedPersonal)
        XCTAssertTrue(reopenedPersonal.isSelected)
        XCTAssertFalse(app.buttons["taskEdit.context.work"].isSelected)
        app.buttons["taskEdit.cancel"].tap()
        XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 3))
    }

    func testTaskEditControlsRemainReachableAtAccessibility5() throws {
        let app = launchApp(
            skipOnboarding: true,
            accessibilityText: true,
            seedLibrary: true
        )
        dismissNotificationPermissionIfPresent(in: app)
        openTaskEditor(for: "Book dentist appointment", in: app)

        let editorTitle = app.staticTexts["taskEdit.title"]
        let cancel = app.buttons["taskEdit.cancel"]
        let save = app.buttons["taskEdit.save"]
        for element in [editorTitle, cancel, save] {
            assertVisible(element)
        }
        XCTAssertEqual(editorTitle.label, "Edit task")
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        XCTAssertTrue(cancel.isHittable)
        assertTaskEditFixedAction(save, in: app)
        let fixedSaveFrame = save.frame
        let fixedCancelFrame = cancel.frame

        let titleField = app.textFields["taskEdit.titleField"]
        let firstStepField = app.textFields["taskEdit.firstStepField"]
        let school = app.buttons["taskEdit.context.school"]
        let work = app.buttons["taskEdit.context.work"]
        let personal = app.buttons["taskEdit.context.personal"]
        let deadline = app.datePickers["taskEdit.deadline"]
        let effortValue = app.staticTexts["taskEdit.effort.value"]
        let decrementEffort = app.buttons["taskEdit.effort.decrement"]
        let incrementEffort = app.buttons["taskEdit.effort.increment"]
        let controls = [titleField, firstStepField, school, work, personal, deadline]

        for control in controls {
            assertTaskEditControlReachable(control, above: save, in: app)
            assertTaskEditFixedAction(save, in: app)
        }
        assertSheetControlReachable(
            effortValue,
            above: save,
            in: app,
            surface: "Task Edit",
            minimumVisibleHeight: 20,
            requiresHitTesting: false,
            file: #filePath,
            line: #line
        )
        for adjustment in [decrementEffort, incrementEffort] {
            assertTaskEditControlReachable(adjustment, above: save, in: app)
        }
        XCTAssertFalse(
            decrementEffort.frame.intersects(incrementEffort.frame),
            "Task Edit effort decrement/increment targets must remain spatially independent. " +
                "decrement=\(decrementEffort.frame), increment=\(incrementEffort.frame)."
        )
        assertTaskEditFixedAction(save, in: app)

        XCTAssertEqual(titleField.elementType, .textField)
        XCTAssertEqual(firstStepField.elementType, .textField)
        XCTAssertEqual(deadline.elementType, .datePicker)
        XCTAssertEqual(effortValue.elementType, .staticText)
        XCTAssertEqual(effortValue.value as? String, "30m")
        XCTAssertTrue(personal.isSelected)
        XCTAssertEqual([school, work, personal].filter(\.isSelected).count, 1)
        for firstIndex in [school, work, personal].indices {
            for secondIndex in [school, work, personal].indices where secondIndex > firstIndex {
                XCTAssertFalse(
                    [school, work, personal][firstIndex].frame.intersects(
                        [school, work, personal][secondIndex].frame
                    ),
                    "Task Edit context controls must not overlap at Accessibility 5."
                )
            }
        }

        XCTAssertEqual(save.frame.minX, fixedSaveFrame.minX, accuracy: 2)
        XCTAssertEqual(save.frame.minY, fixedSaveFrame.minY, accuracy: 2)
        XCTAssertEqual(save.frame.width, fixedSaveFrame.width, accuracy: 2)
        XCTAssertEqual(save.frame.height, fixedSaveFrame.height, accuracy: 2)
        XCTAssertEqual(cancel.frame.minX, fixedCancelFrame.minX, accuracy: 2)
        XCTAssertEqual(cancel.frame.minY, fixedCancelFrame.minY, accuracy: 2)
    }

    func testOverdueTriageOpensDeadlineFirstTaskEditAtAccessibility5() throws {
        let app = launchApp(
            skipOnboarding: true,
            accessibilityText: true,
            seedOverdue: true
        )
        dismissNotificationPermissionIfPresent(in: app)
        assertVisible(app.staticTexts["Needs a decision"])
        assertVisible(app.staticTexts["Overdue triage fixture"])

        let newDeadline = app.buttons["tasks.triage.newDeadline"]
        let complete = app.buttons["tasks.triage.complete"]
        let letGo = app.buttons["tasks.triage.letGo"]
        for action in [newDeadline, complete, letGo] {
            assertVisible(action)
            XCTAssertGreaterThanOrEqual(action.frame.width, 44)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
        }
        let triageActions = [newDeadline, complete, letGo]
        for firstIndex in triageActions.indices {
            for secondIndex in triageActions.indices where secondIndex > firstIndex {
                XCTAssertFalse(
                    triageActions[firstIndex].frame.intersects(triageActions[secondIndex].frame),
                    "Overdue triage actions must remain distinct at Accessibility 5."
                )
            }
        }
        scrollToHittable(newDeadline, in: app)
        newDeadline.tap()

        let editorTitle = app.staticTexts["taskEdit.title"]
        let deadline = app.datePickers["taskEdit.deadline"]
        let deadlineHint = app.staticTexts["taskEdit.deadlineHint"]
        let titleField = app.textFields["taskEdit.titleField"]
        let save = app.buttons["taskEdit.save"]
        for element in [editorTitle, deadline, deadlineHint, titleField, save] {
            assertVisible(element)
        }
        XCTAssertEqual(editorTitle.label, "Choose a new deadline")
        XCTAssertEqual(deadline.label, "New deadline")
        XCTAssertFalse((deadline.value as? String)?.isEmpty ?? true)
        XCTAssertEqual(
            deadlineHint.label,
            "The schedule rebuilds around this choice when you save."
        )
        XCTAssertLessThan(
            deadline.frame.minY,
            titleField.frame.minY,
            "The overdue editor must lead with its fresh deadline decision before task details."
        )
        XCTAssertLessThan(deadlineHint.frame.minY, titleField.frame.minY)
        assertTaskEditFixedAction(save, in: app)
        assertTaskEditControlReachable(deadline, above: save, in: app)
        assertTaskEditControlReachable(titleField, above: save, in: app)

        // The suggested future date is part of the loaded triage draft, so a
        // clean Cancel must not manufacture an unsaved-changes warning.
        app.buttons["taskEdit.cancel"].tap()
        XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Discard unsaved changes?"].exists)
        assertVisible(app.buttons["tasks.triage.newDeadline"])
    }

    func testWeaveTapestryIsOneGenerousInteractiveSurface() throws {
        let app = launchApp(skipOnboarding: true, seedCompletion: true)
        assertWeaveTapestryTouchAndSemantics(in: app)
    }

    func testWeaveTapestryTouchContractAtAccessibility5() throws {
        let app = launchApp(
            skipOnboarding: true,
            accessibilityText: true,
            seedCompletion: true
        )
        assertWeaveTapestryTouchAndSemantics(in: app)
    }

    func testAccessibilityTextKeepsNavigationAndFirstActionReachable() throws {
        let app = launchApp(skipOnboarding: true, accessibilityText: true)

        assertVisible(app.staticTexts["Your Tasks"])

        let tasks = app.buttons["Tasks"]
        let schedule = app.buttons["Schedule"]
        let weave = app.buttons["Weave"]
        let settings = app.buttons["Settings"]
        let capture = app.buttons["tabBar.capture"]
        for control in [tasks, schedule, weave, settings, capture] {
            assertVisible(control)
            XCTAssertTrue(control.isHittable)
        }

        XCTAssertLessThan(tasks.frame.midX, schedule.frame.midX)
        XCTAssertLessThan(tasks.frame.midY, weave.frame.midY)
        XCTAssertLessThan(weave.frame.midX, settings.frame.midX)
        XCTAssertGreaterThan(capture.frame.minY, weave.frame.maxY)

        let firstTaskButton = app.buttons["tasks.empty.addFirst"]
        assertVisible(firstTaskButton)
        scrollToHittable(firstTaskButton, in: app)
    }

    func testTaskCompletionShowsThreadTieAndRestoresTask() throws {
        let app = launchApp(skipOnboarding: true, seedCompletion: true)

        assertVisible(app.staticTexts["Finish launch notes"])
        let completeButton = app.buttons["task.complete"].firstMatch
        assertVisible(completeButton)
        scrollToHittable(completeButton, in: app)
        completeButton.tap()

        assertVisible(app.staticTexts["completion.title"])
        assertVisible(app.staticTexts["completion.eyebrow"])
        XCTAssertFalse(app.staticTexts["right on the wire"].exists)

        let done = app.buttons["completion.done"]
        let restore = app.buttons["completion.restore"]
        assertVisible(done)
        assertVisible(restore)
        XCTAssertTrue(done.isHittable)
        XCTAssertTrue(restore.isHittable)

        restore.tap()
        XCTAssertTrue(app.staticTexts["completion.title"].waitForNonExistence(timeout: 3))
        assertVisible(app.staticTexts["Finish launch notes"])
        assertVisible(app.buttons["task.complete"].firstMatch)
    }

    func testPopulatedTasksExposeFocusAndGroupedLibrary() throws {
        let app = launchApp(skipOnboarding: true, seedLibrary: true)

        let focus = app.descendants(matching: .any)["tasks.section.focus"]
        let library = app.descendants(matching: .any)["tasks.section.library"]
        assertVisible(focus)
        assertVisible(library)
        XCTAssertLessThan(focus.frame.minY, library.frame.minY)

        let school = app.buttons["tasks.context.school"]
        let work = app.buttons["tasks.context.work"]
        let personal = app.buttons["tasks.context.personal"]
        for disclosure in [school, work, personal] {
            assertVisible(disclosure)
            XCTAssertEqual(disclosure.value as? String, "Expanded")
        }
        XCTAssertTrue(school.label.contains("1 task"))
        XCTAssertFalse(school.label.contains("1 tasks"))
        XCTAssertTrue(personal.label.contains("2 tasks"))
        scrollToHittable(personal, in: app)
        personal.tap()
        let collapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.buttons["tasks.context.personal"].value as? String == "Collapsed"
            },
            object: app
        )
        wait(for: [collapsed], timeout: 3)
    }

    func testPopulatedTasksDisclosureAdaptsAtAccessibilityText() throws {
        let app = launchApp(
            skipOnboarding: true,
            accessibilityText: true,
            seedLibrary: true
        )

        let personal = app.buttons["tasks.context.personal"]
        assertVisible(personal)
        scrollToHittable(personal, in: app)
        XCTAssertGreaterThanOrEqual(personal.frame.height, 44)
        XCTAssertTrue(personal.label.contains("2 tasks"))

        personal.tap()
        let collapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.buttons["tasks.context.personal"].value as? String == "Collapsed"
            },
            object: app
        )
        wait(for: [collapsed], timeout: 3)

        personal.tap()
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.buttons["tasks.context.personal"].value as? String == "Expanded"
            },
            object: app
        )
        wait(for: [expanded], timeout: 3)

        let dentistSummary = app.buttons
            .matching(identifier: "task.summary")
            .matching(NSPredicate(
                format: "label BEGINSWITH %@",
                "Book dentist appointment"
            ))
            .firstMatch
        assertVisible(dentistSummary)
        scrollToHittable(dentistSummary, in: app)

        let start = app.buttons["Start work session for Book dentist appointment"]
        let complete = app.buttons["Mark Book dentist appointment complete"]
        assertVisible(start)
        assertVisible(complete)
        XCTAssertGreaterThanOrEqual(start.frame.height, 44)
        XCTAssertGreaterThanOrEqual(complete.frame.height, 44)
        XCTAssertLessThan(start.frame.minY, complete.frame.minY)
        scrollToHittable(start, in: app)
        scrollToHittable(complete, in: app)
    }

    func testWorkSessionRunsPausesLogsAndDismissesReceipt() throws {
        let app = launchApp(skipOnboarding: true, seedLibrary: true)
        openWorkSession(for: "Book dentist appointment", in: app)

        let title = app.staticTexts["workSession.title"]
        let taskTitle = app.staticTexts["workSession.taskTitle"]
        let timer = app.descendants(matching: .any)["workSession.timer"]
        let start = app.buttons["workSession.start"]
        let microStart = app.buttons["workSession.microStart"]
        for element in [title, taskTitle, timer, start, microStart] {
            assertVisible(element)
        }
        XCTAssertEqual(taskTitle.label, "Book dentist appointment")
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(microStart.isHittable)

        start.tap()

        let pause = app.buttons["workSession.pause"]
        let stop = app.buttons["workSession.stop"]
        assertVisible(pause)
        assertVisible(stop)
        XCTAssertTrue(pause.isHittable)
        XCTAssertTrue(stop.isHittable)
        XCTAssertGreaterThanOrEqual(pause.frame.height, 44)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44)

        pause.tap()
        waitForLabel("Resume", on: pause)
        XCTAssertTrue(stop.isHittable, "Pausing must not strand the end-and-log action.")

        pause.tap()
        waitForLabel("Pause", on: pause)
        stop.tap()

        let loggedTitle = app.staticTexts["workSession.loggedTitle"]
        let saveProgress = app.buttons["workSession.saveProgress"]
        let notNow = app.buttons["workSession.notNow"]
        for element in [loggedTitle, saveProgress, notNow] {
            assertVisible(element)
        }
        XCTAssertEqual(loggedTitle.label, "Session logged")
        XCTAssertTrue(saveProgress.isHittable)
        XCTAssertTrue(notNow.isHittable)
        XCTAssertGreaterThanOrEqual(saveProgress.frame.height, 44)
        XCTAssertGreaterThanOrEqual(notNow.frame.height, 44)

        notNow.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 3))
        assertVisible(app.staticTexts["Your Tasks"])
    }

    func testWorkSessionFixedActionsRemainReachableAtAccessibilityText() throws {
        let app = launchApp(
            skipOnboarding: true,
            accessibilityText: true,
            seedLibrary: true
        )
        openWorkSession(for: "Book dentist appointment", in: app)

        let title = app.staticTexts["workSession.title"]
        let close = app.buttons["workSession.close"]
        let timer = app.descendants(matching: .any)["workSession.timer"]
        let start = app.buttons["workSession.start"]
        let microStart = app.buttons["workSession.microStart"]
        assertVisible(close)
        XCTAssertEqual(close.label, "Close")
        assertAccessibleHeaderAction(close, title: title)
        for control in [start, microStart] {
            assertVisible(control)
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }

        start.tap()
        waitForLabel("End", on: close)
        assertAccessibleHeaderAction(close, title: title)

        let pause = app.buttons["workSession.pause"]
        let stop = app.buttons["workSession.stop"]
        for control in [pause, stop] {
            assertVisible(control)
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        XCTAssertLessThan(
            pause.frame.minY,
            stop.frame.minY,
            "Accessibility text should stack the two primary session controls."
        )

        // The actions live in a safe-area inset and must remain fixed while the
        // timer stage scrolls into view. Confirm a useful slice of the 244pt
        // ring can be exposed above that inset without moving either action.
        let pauseFrameBeforeScroll = pause.frame
        let stopFrameBeforeScroll = stop.frame
        assertVisible(timer)
        scrollTimerAboveActionBar(timer, header: title, action: pause, in: app)
        XCTAssertEqual(pause.frame.minY, pauseFrameBeforeScroll.minY, accuracy: 2)
        XCTAssertEqual(stop.frame.minY, stopFrameBeforeScroll.minY, accuracy: 2)
        XCTAssertTrue(pause.isHittable)
        XCTAssertTrue(stop.isHittable)

        pause.tap()
        waitForLabel("Resume", on: pause)
        pause.tap()
        waitForLabel("Pause", on: pause)
        stop.tap()

        let loggedTitle = app.staticTexts["workSession.loggedTitle"]
        let saveProgress = app.buttons["workSession.saveProgress"]
        let notNow = app.buttons["workSession.notNow"]
        assertVisible(loggedTitle)
        for control in [saveProgress, notNow] {
            assertVisible(control)
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }

        notNow.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 3))
        assertVisible(app.staticTexts["Your Tasks"])
    }

    func testCaptureCompletesOnIPadLandscapeWithCappedFormAndFixedAction() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp(skipOnboarding: true)
        let window = app.windows.firstMatch
        assertVisible(window)

        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.frame.width > element.frame.height
            },
            object: window
        )
        wait(for: [landscapeExpectation], timeout: 5)

        let shortEdge = min(window.frame.width, window.frame.height)
        guard shortEdge >= 700 else {
            throw XCTSkip("Run this Capture layout check on an iPad destination.")
        }

        openCapture(in: app)

        let captureTitle = app.staticTexts["capture.title"]
        let titleField = app.textFields["capture.taskTitleField"]
        let voiceInput = app.buttons["capture.voiceInputButton"]
        let primaryAction = app.buttons["capture.primaryAction"]
        for element in [captureTitle, titleField, voiceInput, primaryAction] {
            assertVisible(element)
        }

        let titleRowFrame = titleField.frame.union(voiceInput.frame)
        XCTAssertLessThanOrEqual(
            titleRowFrame.width,
            760,
            "Expected Capture's regular-width form to stay within the readable content cap."
        )
        XCTAssertEqual(
            titleRowFrame.midX,
            window.frame.midX,
            accuracy: 4,
            "Expected the capped Capture form to remain centered in landscape."
        )
        XCTAssertLessThanOrEqual(
            primaryAction.frame.width,
            760,
            "Expected the fixed Capture action to share the readable-width cap."
        )
        XCTAssertEqual(
            primaryAction.frame.midX,
            window.frame.midX,
            accuracy: 4,
            "Expected the fixed Capture action to remain centered in landscape."
        )

        // Reuse this regular-width session to verify Bulk's capped row and
        // fixed dual-action boundary, then discard the probe and return to the
        // single-capture journey below.
        let bulkButton = app.buttons["capture.bulk"]
        assertVisible(bulkButton)
        bulkButton.tap()

        let bulkTitle = app.staticTexts["bulk.title"]
        let bulkBack = app.buttons["bulk.back"]
        let bulkRowTitle = app.textFields["bulk.row.1.title"]
        let bulkDeadline = app.descendants(matching: .any)["bulk.row.1.deadline"]
        let bulkAddRow = app.buttons["bulk.addRow"]
        let bulkSchedule = app.buttons["bulk.scheduleAll"]
        for element in [bulkTitle, bulkBack, bulkRowTitle, bulkDeadline, bulkAddRow, bulkSchedule] {
            assertVisible(element)
        }

        bulkRowTitle.tap()
        bulkRowTitle.typeText("iPad bulk layout probe")
        dismissKeyboardIfNeeded(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        assertBulkAction(bulkAddRow, in: app)
        assertBulkAction(bulkSchedule, in: app)

        XCTAssertLessThanOrEqual(
            bulkRowTitle.frame.width,
            760,
            "Expected Bulk's regular-width row to stay within the readable content cap."
        )
        XCTAssertEqual(
            bulkRowTitle.frame.midX,
            window.frame.midX,
            accuracy: 4,
            "Expected the capped Bulk form to remain centered in landscape."
        )
        let bulkActionUnion = bulkAddRow.frame.union(bulkSchedule.frame)
        XCTAssertLessThanOrEqual(
            bulkActionUnion.width,
            760,
            "Expected Bulk's fixed actions to share the readable-width cap."
        )
        XCTAssertEqual(
            bulkActionUnion.midX,
            window.frame.midX,
            accuracy: 4,
            "Expected Bulk's fixed actions to remain centered in landscape."
        )
        let fixedBulkAddFrame = bulkAddRow.frame
        let fixedBulkScheduleFrame = bulkSchedule.frame
        assertBulkControlReachable(
            bulkDeadline,
            above: bulkSchedule,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        assertFixedBulkAction(bulkAddRow, matches: fixedBulkAddFrame)
        assertFixedBulkAction(bulkSchedule, matches: fixedBulkScheduleFrame)

        bulkBack.tap()
        let discardBulk = app.buttons["Discard"]
        assertVisible(discardBulk)
        discardBulk.tap()
        XCTAssertTrue(bulkTitle.waitForNonExistence(timeout: 3))
        assertVisible(captureTitle)

        let exactTitle = "Prepare the subscription launch"
        titleField.tap()
        titleField.typeText(exactTitle)
        XCTAssertEqual(titleField.value as? String, exactTitle)
        dismissKeyboardIfNeeded(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        assertCapturePrimaryAction(primaryAction, in: app)
        let fixedActionFrame = primaryAction.frame

        let workContext = app.buttons["capture.context.work"]
        let thirtyMinutes = app.buttons["capture.effort.30"]
        let schedulingOptions = app.buttons["capture.moreSchedulingOptions"]
        for choice in [workContext, thirtyMinutes] {
            assertCaptureControlReachable(
                choice,
                above: primaryAction,
                in: app,
                minimumVisibleHeight: 44,
                requiresHitTesting: true
            )
            assertFixedCaptureAction(primaryAction, matches: fixedActionFrame)
            choice.tap()
            assertSelected(choice)
        }
        assertCaptureControlReachable(
            schedulingOptions,
            above: primaryAction,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true
        )
        assertFixedCaptureAction(primaryAction, matches: fixedActionFrame)

        assertCapturePrimaryAction(primaryAction, in: app)
        primaryAction.tap()
        assertCaptureHandoff(
            taskTitle: exactTitle,
            captureTitle: captureTitle,
            in: app
        )
        XCTAssertEqual(XCUIDevice.shared.orientation, .landscapeLeft)
    }

    /// Focused adaptive-layout smoke test. It skips on iPhone destinations so
    /// the regular phone suite stays fast, and exercises the same four core
    /// surfaces in the iPad orientation most likely to expose runaway widths.
    func testIPadLandscapeCoreNavigation() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp(skipOnboarding: true)
        let window = app.windows.firstMatch
        assertVisible(window)

        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.frame.width > element.frame.height
            },
            object: window
        )
        wait(for: [landscapeExpectation], timeout: 5)

        let shortEdge = min(window.frame.width, window.frame.height)
        guard shortEdge >= 700 else {
            throw XCTSkip("Run this focused adaptive-layout check on an iPad destination.")
        }

        assertVisible(app.staticTexts["Your Tasks"])
        let firstTaskButton = app.buttons["tasks.empty.addFirst"]
        assertVisible(firstTaskButton)
        XCTAssertTrue(firstTaskButton.isHittable)
        visitTab("Schedule", showing: "Schedule", in: app)
        visitTab("Weave", showing: "Your Weave", in: app)
        visitTab("Settings", showing: "Settings", in: app)
        visitTab("Tasks", showing: "Your Tasks", in: app)

        let tasksButton = app.buttons["Tasks"]
        let captureButton = app.buttons["Capture a task"]
        assertVisible(tasksButton)
        assertVisible(captureButton)
        XCTAssertTrue(tasksButton.isHittable)
        XCTAssertTrue(captureButton.isHittable)
        XCTAssertLessThanOrEqual(
            captureButton.frame.maxX - tasksButton.frame.minX,
            620,
            "Expected the iPad tab bar controls to remain centered at a readable width."
        )
    }

    func testOnboardingCompletesOnIPadLandscapeWithFixedActions() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp()
        let window = app.windows.firstMatch
        assertVisible(window)

        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.frame.width > element.frame.height
            },
            object: window
        )
        wait(for: [landscapeExpectation], timeout: 5)

        let shortEdge = min(window.frame.width, window.frame.height)
        guard shortEdge >= 700 else {
            throw XCTSkip("Run this onboarding layout check on an iPad destination.")
        }

        let welcomeTitle = app.staticTexts["You add the task. Filuma finds the time."]
        let startWithDefaults = app.buttons["onboarding.startWithDefaults"]
        let customize = app.buttons["onboarding.customize"]
        for element in [welcomeTitle, startWithDefaults, customize] {
            assertVisible(element)
        }
        XCTAssertGreaterThan(
            welcomeTitle.frame.midX,
            window.frame.midX,
            "Expected the regular-width welcome copy to sit beside the journey illustration."
        )
        assertOnboardingAction(startWithDefaults)
        assertOnboardingAction(customize)
        let defaultsFrame = startWithDefaults.frame
        let customizeFrame = customize.frame
        app.swipeUp()
        assertFixedOnboardingAction(startWithDefaults, matches: defaultsFrame)
        assertFixedOnboardingAction(customize, matches: customizeFrame)

        customize.tap()

        let dayTitle = app.staticTexts["onboarding.day.title"]
        let wakeTime = app.descendants(matching: .any)["onboarding.wakeTime"]
        let sleepTime = app.descendants(matching: .any)["onboarding.sleepTime"]
        let dayContinue = app.buttons["onboarding.continue"]
        let dayBack = app.buttons["onboarding.back"]
        for element in [dayTitle, wakeTime, sleepTime, dayContinue, dayBack] {
            assertVisible(element)
        }
        assertOnboardingAction(dayContinue)
        assertOnboardingAction(dayBack)
        let dayContinueFrame = dayContinue.frame
        let dayBackFrame = dayBack.frame
        for editor in [wakeTime, sleepTime] {
            assertOnboardingContentReachable(editor, above: dayContinue, in: app, minimumVisibleHeight: 44)
        }
        assertFixedOnboardingAction(dayContinue, matches: dayContinueFrame)
        assertFixedOnboardingAction(dayBack, matches: dayBackFrame)

        dayContinue.tap()

        let blocksTitle = app.staticTexts["onboarding.blocks.title"]
        let minimumBlock = app.descendants(matching: .any)["onboarding.minimumBlock"]
        let maximumBlock = app.descendants(matching: .any)["onboarding.maximumBlock"]
        let deadlineBuffer = app.descendants(matching: .any)["onboarding.deadlineBuffer"]
        let finish = app.buttons["onboarding.finish"]
        let blocksBack = app.buttons["onboarding.back"]
        for element in [blocksTitle, minimumBlock, maximumBlock, deadlineBuffer, finish, blocksBack] {
            assertVisible(element)
        }
        assertOnboardingAction(finish)
        assertOnboardingAction(blocksBack)
        let finishFrame = finish.frame
        let blocksBackFrame = blocksBack.frame
        for editor in [minimumBlock, maximumBlock, deadlineBuffer] {
            assertOnboardingContentReachable(editor, above: finish, in: app, minimumVisibleHeight: 44)
        }
        assertFixedOnboardingAction(finish, matches: finishFrame)
        assertFixedOnboardingAction(blocksBack, matches: blocksBackFrame)

        finish.tap()
        assertVisible(app.staticTexts["Your Tasks"])
        assertVisible(app.staticTexts["tasks.empty.firstTitle"])
        assertVisible(app.buttons["tasks.empty.addFirst"])
        XCTAssertTrue(app.buttons["Tasks"].isSelected)
    }

    private func openCapture(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        dismissNotificationPermissionIfPresent(in: app)
        let capture = app.buttons["tabBar.capture"]
        assertVisible(capture, file: file, line: line)
        XCTAssertTrue(capture.isHittable, file: file, line: line)
        capture.tap()
        assertVisible(app.staticTexts["capture.title"], file: file, line: line)
    }

    private func dismissNotificationPermissionIfPresent(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for alert in [app.alerts.firstMatch, springboard.alerts.firstMatch] {
            guard alert.waitForExistence(timeout: 1) else { continue }
            for label in ["Don’t Allow", "Don't Allow"] {
                let deny = alert.buttons[label]
                if deny.exists {
                    deny.tap()
                    XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
                    return
                }
            }
        }
    }

    private func openBulkCapture(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openCapture(in: app, file: file, line: line)
        let bulk = app.buttons["capture.bulk"]
        assertVisible(bulk, file: file, line: line)
        XCTAssertTrue(bulk.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(bulk.frame.height, 44, file: file, line: line)
        bulk.tap()
        assertVisible(app.staticTexts["bulk.title"], file: file, line: line)
    }

    private func assertCapturePrimaryAction(
        _ action: XCUIElement,
        above occludingElement: XCUIElement? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(action, file: file, line: line)
        XCTAssertTrue(action.isEnabled, file: file, line: line)
        XCTAssertTrue(action.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            action.frame.minX,
            app.frame.minX - 2,
            "Expected the fixed Capture action's leading edge to remain visible.",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            action.frame.maxX,
            app.frame.maxX + 2,
            "Expected the fixed Capture action's trailing edge to remain visible.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            action.frame.minY,
            app.frame.minY - 2,
            "Expected the fixed Capture action's top edge to remain visible.",
            file: file,
            line: line
        )
        let visibleBottom = occludingElement?.frame.minY ?? app.frame.maxY
        XCTAssertLessThanOrEqual(
            action.frame.maxY,
            visibleBottom + 2,
            occludingElement == nil
                ? "Expected the fixed Capture action's bottom edge to remain visible."
                : "Expected the fixed Capture action to remain fully above the visible keyboard.",
            file: file,
            line: line
        )
    }

    private func assertFixedCaptureAction(
        _ action: XCUIElement,
        matches originalFrame: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(action.frame.minX, originalFrame.minX, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.minY, originalFrame.minY, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.width, originalFrame.width, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.height, originalFrame.height, accuracy: 2, file: file, line: line)
        XCTAssertTrue(action.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44, file: file, line: line)
    }

    private func assertBulkAction(
        _ action: XCUIElement,
        above occludingElement: XCUIElement? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(action, file: file, line: line)
        XCTAssertTrue(action.isEnabled, file: file, line: line)
        XCTAssertTrue(action.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            action.frame.minX,
            app.frame.minX - 2,
            "Expected Bulk's fixed action leading edge to remain visible.",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            action.frame.maxX,
            app.frame.maxX + 2,
            "Expected Bulk's fixed action trailing edge to remain visible.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            action.frame.minY,
            app.frame.minY - 2,
            "Expected Bulk's fixed action top edge to remain visible.",
            file: file,
            line: line
        )
        let visibleBottom = occludingElement?.frame.minY ?? app.frame.maxY
        XCTAssertLessThanOrEqual(
            action.frame.maxY,
            visibleBottom + 2,
            occludingElement == nil
                ? "Expected Bulk's fixed action bottom edge to remain visible."
                : "Expected Bulk's fixed action to remain fully above the visible keyboard.",
            file: file,
            line: line
        )
    }

    private func assertFixedBulkAction(
        _ action: XCUIElement,
        matches originalFrame: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(action.frame.minX, originalFrame.minX, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.minY, originalFrame.minY, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.width, originalFrame.width, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.height, originalFrame.height, accuracy: 2, file: file, line: line)
        XCTAssertTrue(action.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44, file: file, line: line)
    }

    private func assertSelected(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.isSelected
            },
            object: element
        )
        let result = XCTWaiter.wait(for: [selected], timeout: 3)
        XCTAssertEqual(
            result,
            .completed,
            "Expected \(element.identifier) to expose its selected accessibility state.",
            file: file,
            line: line
        )
    }

    private func waitForValue(
        _ expectedValue: String,
        on element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let valueChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.value as? String == expectedValue
            },
            object: element
        )
        let result = XCTWaiter.wait(for: [valueChanged], timeout: 3)
        XCTAssertEqual(
            result,
            .completed,
            "Expected \(element.identifier) to expose value \(expectedValue).",
            file: file,
            line: line
        )
    }

    private func assertCaptureControlReachable(
        _ element: XCUIElement,
        above fixedAction: XCUIElement,
        in app: XCUIApplication,
        minimumVisibleHeight: CGFloat = 20,
        requiresHitTesting: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertSheetControlReachable(
            element,
            above: fixedAction,
            in: app,
            surface: "Capture",
            minimumVisibleHeight: minimumVisibleHeight,
            requiresHitTesting: requiresHitTesting,
            file: file,
            line: line
        )
    }

    private func assertBulkControlReachable(
        _ element: XCUIElement,
        above fixedAction: XCUIElement,
        in app: XCUIApplication,
        minimumVisibleHeight: CGFloat = 20,
        requiresHitTesting: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertSheetControlReachable(
            element,
            above: fixedAction,
            in: app,
            surface: "Bulk",
            minimumVisibleHeight: minimumVisibleHeight,
            requiresHitTesting: requiresHitTesting,
            file: file,
            line: line
        )
    }

    private func assertTaskEditControlReachable(
        _ element: XCUIElement,
        above fixedAction: XCUIElement,
        in app: XCUIApplication,
        requiresHitTesting: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertSheetControlReachable(
            element,
            above: fixedAction,
            in: app,
            surface: "Task Edit",
            minimumVisibleHeight: 44,
            requiresHitTesting: requiresHitTesting,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.width,
            44,
            "Expected \(element.identifier) to preserve a 44pt semantic width. " +
                "Frame=\(element.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.height,
            44,
            "Expected \(element.identifier) to preserve a 44pt semantic height. " +
                "Frame=\(element.frame).",
            file: file,
            line: line
        )
    }

    private func assertTaskEditFixedAction(
        _ save: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(save, file: file, line: line)
        XCTAssertEqual(save.elementType, .button, file: file, line: line)
        XCTAssertTrue(
            save.isHittable,
            "Expected Task Edit's fixed Save action to remain independently hittable. " +
                "Save=\(save.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(save.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44, file: file, line: line)
        XCTAssertTrue(
            app.frame.contains(save.frame),
            "Expected Task Edit's fixed Save action to remain fully onscreen. " +
                "App=\(app.frame), save=\(save.frame).",
            file: file,
            line: line
        )
    }

    private func assertSheetControlReachable(
        _ element: XCUIElement,
        above fixedAction: XCUIElement,
        in app: XCUIApplication,
        surface: String,
        minimumVisibleHeight: CGFloat,
        requiresHitTesting: Bool,
        file: StaticString,
        line: UInt
    ) {
        // CoreGraphics can expose an authored 44pt SwiftUI frame as
        // 43.999999999999886 after sheet-coordinate conversion. Keep the
        // product floor at 44 while allowing only sub-pixel floating error.
        let geometryTolerance: CGFloat = 0.01
        assertVisible(element, file: file, line: line)
        let scrollView = app.scrollViews.allElementsBoundByIndex
            .first(where: \.isHittable) ?? app.scrollViews.firstMatch
        assertVisible(scrollView, file: file, line: line)
        var geometrySamples: [String] = []

        func visibleHeight() -> CGFloat {
            guard element.exists, fixedAction.exists else { return 0 }
            let viewportTop = scrollView.frame.minY + 8
            let viewportBottom = min(scrollView.frame.maxY, fixedAction.frame.minY) - 8
            let viewport = CGRect(
                x: scrollView.frame.minX,
                y: viewportTop,
                width: scrollView.frame.width,
                height: max(0, viewportBottom - viewportTop)
            )
            return element.frame.intersection(viewport).height
        }

        for _ in 0..<12 {
            let currentVisibleHeight = visibleHeight()
            geometrySamples.append(
                "element=\(element.frame), action=\(fixedAction.frame), visible=\(currentVisibleHeight), hittable=\(element.isHittable)"
            )
            let isReady = currentVisibleHeight >= minimumVisibleHeight - geometryTolerance
                && (!requiresHitTesting || element.isHittable)
            if isReady { break }

            let viewportTop = scrollView.frame.minY + 8
            let viewportBottom = min(scrollView.frame.maxY, fixedAction.frame.minY) - 8
            let viewportCenter = (viewportTop + viewportBottom) / 2
            let travel = min(120, max(64, (viewportBottom - viewportTop) * 0.22))
            let shouldMoveContentUp = element.frame.isEmpty || element.frame.midY > viewportCenter
            let startY = viewportCenter + (shouldMoveContentUp ? travel / 2 : -travel / 2)
            let endY = viewportCenter + (shouldMoveContentUp ? -travel / 2 : travel / 2)
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: (startY - scrollView.frame.minY) / scrollView.frame.height
            ))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: (endY - scrollView.frame.minY) / scrollView.frame.height
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        XCTAssertGreaterThanOrEqual(
            visibleHeight(),
            minimumVisibleHeight - geometryTolerance,
            "Expected \(element.identifier) to remain revealable above \(surface)'s fixed action. Samples: \(geometrySamples.joined(separator: " | "))",
            file: file,
            line: line
        )
        if requiresHitTesting {
            XCTAssertTrue(
                element.isHittable,
                "Expected \(element.identifier) to remain hittable. Samples: \(geometrySamples.joined(separator: " | "))",
                file: file,
                line: line
            )
        }
    }

    private func materializeSheetControl(
        _ element: XCUIElement,
        in app: XCUIApplication,
        surface: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if element.waitForExistence(timeout: 1) { return }

        let scrollView = app.scrollViews.allElementsBoundByIndex
            .first(where: \.isHittable) ?? app.scrollViews.firstMatch
        assertVisible(scrollView, file: file, line: line)
        for _ in 0..<12 where !element.exists {
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(
            element.waitForExistence(timeout: 1),
            "Expected the \(surface) control to materialize while scrolling the sheet.",
            file: file,
            line: line
        )
    }

    private func assertCaptureHandoff(
        taskTitle: String,
        captureTitle: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let success = app.descendants(matching: .any)["capture.success"]
        // Task success is intentionally a brief receipt before automatic
        // dismissal. Validate its semantics when XCTest samples it, while the
        // durable contract below remains sheet disappearance plus task handoff.
        if success.waitForExistence(timeout: 1) {
            XCTAssertTrue(success.isEnabled, file: file, line: line)
            XCTAssertGreaterThanOrEqual(success.frame.height, 44, file: file, line: line)
        }
        XCTAssertTrue(
            captureTitle.waitForNonExistence(timeout: 5),
            "Expected the successful Capture sheet to dismiss durably.",
            file: file,
            line: line
        )

        assertVisible(app.staticTexts["Your Tasks"], file: file, line: line)
        let tasks = app.buttons["Tasks"]
        assertVisible(tasks, file: file, line: line)
        XCTAssertTrue(tasks.isSelected, "Expected successful Capture to hand off to Tasks.", file: file, line: line)

        assertTaskTitleVisibleExactly(taskTitle, in: app, file: file, line: line)
    }

    private func assertBulkReceiptContainsExactTitle(
        _ taskTitle: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let receiptRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", taskTitle))
            .firstMatch
        assertVisible(receiptRow, file: file, line: line)
        let capturedTitle = receiptRow.label
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
        XCTAssertEqual(
            capturedTitle,
            taskTitle,
            "Expected Bulk's success receipt to preserve the exact entered title.",
            file: file,
            line: line
        )
    }

    private func assertBulkHandoff(
        taskTitles: [String],
        bulkTitle: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            bulkTitle.waitForNonExistence(timeout: 5),
            "Expected Bulk's completed flow to dismiss durably.",
            file: file,
            line: line
        )
        XCTAssertFalse(app.staticTexts["capture.title"].exists, file: file, line: line)
        assertVisible(app.staticTexts["Your Tasks"], file: file, line: line)
        let tasks = app.buttons["Tasks"]
        assertVisible(tasks, file: file, line: line)
        XCTAssertTrue(tasks.isSelected, "Expected Bulk to hand off to Tasks.", file: file, line: line)
        for taskTitle in taskTitles {
            assertTaskTitleVisibleExactly(taskTitle, in: app, file: file, line: line)
        }
    }

    private func assertTaskTitleVisibleExactly(
        _ taskTitle: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let newTask = app.buttons
            .matching(identifier: "task.summary")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(taskTitle), "))
            .firstMatch
        assertVisible(newTask, file: file, line: line)
        let capturedTitle = newTask.label
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
        XCTAssertEqual(
            capturedTitle,
            taskTitle,
            "Expected the new task handoff to preserve the exact entered title.",
            file: file,
            line: line
        )
    }

    private func assertOnboardingDayStage(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(app.staticTexts["onboarding.day.title"], file: file, line: line)
        for identifier in ["onboarding.wakeTime", "onboarding.sleepTime"] {
            let control = app.descendants(matching: .any)[identifier]
            assertVisible(control, file: file, line: line)
            XCTAssertTrue(control.isEnabled, "Expected \(identifier) to remain editable.", file: file, line: line)
        }
        assertVisible(app.buttons["onboarding.continue"], file: file, line: line)
        assertVisible(app.buttons["onboarding.back"], file: file, line: line)
    }

    private func assertOnboardingBlocksStage(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(app.staticTexts["onboarding.blocks.title"], file: file, line: line)
        for identifier in [
            "onboarding.minimumBlock",
            "onboarding.maximumBlock",
            "onboarding.deadlineBuffer"
        ] {
            let control = app.descendants(matching: .any)[identifier]
            assertVisible(control, file: file, line: line)
            XCTAssertTrue(control.isEnabled, "Expected \(identifier) to remain editable.", file: file, line: line)
        }
        assertVisible(app.buttons["onboarding.finish"], file: file, line: line)
        assertVisible(app.buttons["onboarding.back"], file: file, line: line)
    }

    private func assertOnboardingAction(
        _ action: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(action, file: file, line: line)
        XCTAssertTrue(action.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44, file: file, line: line)
    }

    private func assertFixedOnboardingAction(
        _ action: XCUIElement,
        matches originalFrame: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(action.frame.minX, originalFrame.minX, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.minY, originalFrame.minY, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.width, originalFrame.width, accuracy: 2, file: file, line: line)
        XCTAssertEqual(action.frame.height, originalFrame.height, accuracy: 2, file: file, line: line)
        XCTAssertTrue(action.isHittable, file: file, line: line)
    }

    private func assertOnboardingEditableControl(
        _ control: XCUIElement,
        above fixedAction: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertOnboardingContentReachable(
            control,
            above: fixedAction,
            in: app,
            minimumVisibleHeight: 44,
            requiresHitTesting: true,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.height,
            44,
            "Expected an Accessibility 5 editor to preserve a 44pt touch target.",
            file: file,
            line: line
        )
    }

    private func assertOnboardingContentReachable(
        _ element: XCUIElement,
        above fixedAction: XCUIElement,
        in app: XCUIApplication,
        minimumVisibleHeight: CGFloat = 20,
        requiresHitTesting: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var geometrySamples: [String] = []

        func visibleHeight() -> CGFloat {
            guard element.exists, fixedAction.exists else { return 0 }
            let viewport = CGRect(
                x: app.frame.minX,
                y: app.frame.minY,
                width: app.frame.width,
                height: max(0, fixedAction.frame.minY - app.frame.minY - 8)
            )
            return element.frame.intersection(viewport).height
        }

        func interactionIsReachable() -> Bool {
            element.isHittable
        }

        for _ in 0..<12 {
            let currentVisibleHeight = visibleHeight()
            geometrySamples.append(
                "element=\(element.frame), action=\(fixedAction.frame), visible=\(currentVisibleHeight), interactionReachable=\(interactionIsReachable())"
            )
            let isReady = currentVisibleHeight >= minimumVisibleHeight
                && (!requiresHitTesting || interactionIsReachable())
            if isReady { break }

            let viewportTop = app.frame.minY + 8
            let viewportBottom = fixedAction.frame.minY - 8
            let viewportCenter = (viewportTop + viewportBottom) / 2
            let travel = min(120, max(64, (viewportBottom - viewportTop) * 0.22))
            let shouldMoveContentUp = element.frame.isEmpty || element.frame.midY > viewportCenter
            let startY = viewportCenter + (shouldMoveContentUp ? travel / 2 : -travel / 2)
            let endY = viewportCenter + (shouldMoveContentUp ? -travel / 2 : travel / 2)
            let start = app.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: (startY - app.frame.minY) / app.frame.height
            ))
            let end = app.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: (endY - app.frame.minY) / app.frame.height
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        XCTAssertGreaterThanOrEqual(
            visibleHeight(),
            minimumVisibleHeight,
            "Expected \(element) to remain revealable above the fixed onboarding actions. Samples: \(geometrySamples.joined(separator: " | "))",
            file: file,
            line: line
        )
        if requiresHitTesting {
            XCTAssertTrue(
                interactionIsReachable(),
                "Expected the editor control to be hittable. Samples: \(geometrySamples.joined(separator: " | "))",
                file: file,
                line: line
            )
        }
    }

    private func launchApp(
        skipOnboarding: Bool = false,
        accessibilityText: Bool = false,
        seedCompletion: Bool = false,
        seedLibrary: Bool = false,
        seedFreeBoundary: Bool = false,
        seedSchedule: Bool = false,
        seedOverdue: Bool = false,
        freeTier: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        if skipOnboarding {
            app.launchArguments.append("-ui-testing-skip-onboarding")
        }
        if accessibilityText {
            app.launchArguments.append("-ui-testing-accessibility-text")
        }
        if seedCompletion {
            app.launchArguments.append("-ui-testing-seed-completion")
        }
        if seedLibrary {
            app.launchArguments.append("-ui-testing-seed-library")
        }
        if seedFreeBoundary {
            app.launchArguments.append("-ui-testing-seed-free-boundary")
        }
        if seedSchedule {
            app.launchArguments.append("-ui-testing-seed-schedule")
        }
        if seedOverdue {
            app.launchArguments.append("-ui-testing-seed-overdue")
        }
        if freeTier {
            app.launchArguments.append("-ui-testing-free")
        }
        app.launch()
        return app
    }

    private func element(labeled label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func taskSummary(named title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(identifier: "task.summary")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), "))
            .firstMatch
    }

    private func openTaskEditor(
        for taskTitle: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let summary = taskSummary(named: taskTitle, in: app)
        assertVisible(summary, file: file, line: line)
        scrollToHittable(summary, in: app, file: file, line: line)

        let start = app.buttons
            .matching(identifier: "task.start")
            .matching(NSPredicate(
                format: "label == %@",
                "Start work session for \(taskTitle)"
            ))
            .firstMatch
        let complete = app.buttons
            .matching(identifier: "task.complete")
            .matching(NSPredicate(
                format: "label == %@",
                "Mark \(taskTitle) complete"
            ))
            .firstMatch
        assertVisible(start, file: file, line: line)
        assertVisible(complete, file: file, line: line)
        XCTAssertFalse(
            summary.frame.intersects(start.frame) || summary.frame.intersects(complete.frame),
            "Task row controls must remain spatially independent. " +
                "summary=\(summary.frame), start=\(start.frame), complete=\(complete.frame).",
            file: file,
            line: line
        )
        XCTAssertEqual(
            summary.buttons.count,
            0,
            "task.summary must be the native Button host, not a synthetic Button " +
                "wrapping a second actionable child. summary=\(summary.frame).",
            file: file,
            line: line
        )

        summary.tap()
        let editorTitle = app.staticTexts["taskEdit.title"]
        XCTAssertTrue(
            editorTitle.waitForExistence(timeout: 5),
            "Expected task.summary to mount Task Edit. summary=\(summary.frame), " +
                "start=\(start.frame), complete=\(complete.frame), " +
                "summaryHittable=\(summary.isHittable).",
            file: file,
            line: line
        )
    }

    private func openWorkSession(
        for taskTitle: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let start = app.buttons["Start work session for \(taskTitle)"]
        assertVisible(start, file: file, line: line)
        scrollToHittable(start, in: app, file: file, line: line)
        start.tap()
        assertVisible(app.staticTexts["workSession.title"], file: file, line: line)
    }

    private func waitForLabel(
        _ expectedLabel: String,
        on element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.label == expectedLabel
            },
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    private func waitForLabelChange(
        from previousLabel: String,
        on element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && !element.label.isEmpty && element.label != previousLabel
            },
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 3)
        XCTAssertEqual(
            result,
            .completed,
            "Expected \(element.identifier) to change from \(previousLabel). Current=\(element.label).",
            file: file,
            line: line
        )
    }

    private func waitForStableFrame(
        of element: XCUIElement,
        accuracy: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect {
        var previousFrame: CGRect?
        var stableObservations = 0
        let deadline = Date().addingTimeInterval(6)

        // AX frame reads are relatively expensive during a sheet's system
        // presentation transform. Poll explicitly so an initial moving sample
        // cannot consume the entire predicate-expectation budget.
        while Date() < deadline {
            if element.exists {
                let frame = element.frame
                if let previousFrame {
                    let isStable = abs(frame.minX - previousFrame.minX) <= accuracy
                        && abs(frame.minY - previousFrame.minY) <= accuracy
                        && abs(frame.width - previousFrame.width) <= accuracy
                        && abs(frame.height - previousFrame.height) <= accuracy
                    stableObservations = isStable ? stableObservations + 1 : 0
                }
                previousFrame = frame
                if stableObservations >= 2 {
                    return frame
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail(
            "Expected \(element.identifier) to settle before fixed-frame comparison. " +
                "Last frame=\(element.frame).",
            file: file,
            line: line
        )
        return previousFrame ?? element.frame
    }

    private func assertAccessibleHeaderAction(
        _ action: XCUIElement,
        title: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(action.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44, file: file, line: line)
        XCTAssertFalse(
            action.frame.intersects(title.frame),
            "Expected the Work Session title and Close/End action to remain spatially distinct.",
            file: file,
            line: line
        )
    }

    private func scrollTimerAboveActionBar(
        _ timer: XCUIElement,
        header: XCUIElement,
        action: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func visibleTimerHeight() -> CGFloat {
            guard timer.exists, header.exists, action.exists else { return 0 }
            let viewport = CGRect(
                x: app.frame.minX,
                y: header.frame.maxY,
                width: app.frame.width,
                height: max(0, action.frame.minY - header.frame.maxY)
            )
            return timer.frame.intersection(viewport).height
        }

        for _ in 0..<8 where visibleTimerHeight() < 44 {
            app.swipeUp()
        }
        XCTAssertGreaterThanOrEqual(
            visibleTimerHeight(),
            44,
            "Expected the core timer to remain revealable above the fixed action bar.",
            file: file,
            line: line
        )
    }

    private func assertWeaveTapestryTouchAndSemantics(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        dismissNotificationPermissionIfPresent(in: app)
        visitTab("Weave", showing: "Your Weave", in: app)

        let tapestryMatches = app.descendants(matching: .any)
            .matching(identifier: "weave.tapestry")
        XCTAssertEqual(
            tapestryMatches.count,
            1,
            "Expected the two-week chart to expose one authored accessibility surface.",
            file: file,
            line: line
        )
        let tapestry = tapestryMatches.firstMatch
        assertVisible(tapestry, file: file, line: line)
        scrollToHittable(tapestry, in: app, file: file, line: line)

        XCTAssertTrue(tapestry.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            tapestry.frame.width,
            min(280, app.frame.width * 0.7),
            "Expected weave.tapestry to remain a generous chart-wide target. " +
                "Frame=\(tapestry.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            tapestry.frame.height,
            130,
            "Expected weave.tapestry to retain its full plot-height target. " +
                "Frame=\(tapestry.frame).",
            file: file,
            line: line
        )

        let tinyChartButtons = app.buttons.allElementsBoundByIndex.filter {
            $0.frame.intersects(tapestry.frame)
        }
        XCTAssertTrue(
            tinyChartButtons.isEmpty,
            "Expected no per-day pseudo-buttons inside weave.tapestry. Found " +
                "\(tinyChartButtons.map { "\($0.identifier)=\($0.frame)" }).",
            file: file,
            line: line
        )

        let initialValue = tapestry.value as? String ?? ""
        XCTAssertTrue(
            initialValue.hasPrefix("No day selected."),
            "Expected the initial adjustable value to summarize the unselected two-week weave. " +
                "Value=\(initialValue).",
            file: file,
            line: line
        )
        func tapDay(at horizontalFraction: CGFloat, after previousValue: String) -> String {
            tapestry.coordinate(withNormalizedOffset: CGVector(
                dx: horizontalFraction,
                dy: 0.5
            )).tap()
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate { object, _ in
                    guard let element = object as? XCUIElement,
                          let value = element.value as? String else { return false }
                    return !value.isEmpty
                        && value != previousValue
                        && !value.hasPrefix("No day selected.")
                },
                object: tapestry
            )
            let result = XCTWaiter.wait(for: [changed], timeout: 3)
            XCTAssertEqual(
                result,
                .completed,
                "Expected a chart tap at x=\(horizontalFraction) to select its day detail. " +
                    "Previous=\(previousValue), current=\(tapestry.value ?? "nil").",
                file: file,
                line: line
            )
            let currentValue = tapestry.value as? String ?? ""
            assertVisible(app.staticTexts[currentValue], file: file, line: line)
            return currentValue
        }

        // Public XCUI automation does not expose SwiftUI's VoiceOver
        // accessibilityAdjustableAction on an `.other` element. Exercise the
        // chart's authored touch contract at two distant columns and verify
        // that the same accessibility value and visible detail advance.
        let firstDayValue = tapDay(at: 0.14, after: initialValue)
        let secondDayValue = tapDay(at: 0.86, after: firstDayValue)
        XCTAssertNotEqual(
            firstDayValue,
            secondDayValue,
            "Distinct chart columns must select distinct day details.",
            file: file,
            line: line
        )
    }

    private func visitTab(_ tab: String, showing title: String, in app: XCUIApplication) {
        let button = app.buttons[tab]
        assertVisible(button)
        button.tap()
        assertVisible(app.staticTexts[title])
        XCTAssertTrue(button.isSelected, "Expected \(tab) to be selected")
    }

    private func dismissKeyboardIfNeeded(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 1) else { return }
        let next = keyboard.buttons
            .matching(NSPredicate(format: "label ==[c] %@", "next"))
            .firstMatch
        if next.exists {
            next.tap()
        }
        let done = keyboard.buttons
            .matching(NSPredicate(format: "label ==[c] %@", "done"))
            .firstMatch
        if done.waitForExistence(timeout: 1) {
            done.tap()
        }
    }

    private func scheduleWeekdayHeaders(in app: XCUIApplication) -> [XCUIElement] {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedule.weekday."))
            .allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    private func assertScheduleNavigationControl(
        _ control: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(control, file: file, line: line)
        let dockTop = ["Tasks", "Schedule", "Weave", "Settings", "tabBar.capture"]
            .compactMap { identifier -> CGFloat? in
                let item = app.buttons[identifier]
                guard item.exists, item.isHittable else { return nil }
                return item.frame.minY
            }
            .min() ?? app.frame.maxY
        let viewport = CGRect(
            x: app.frame.minX,
            y: app.frame.minY,
            width: app.frame.width,
            height: max(0, dockTop - 8 - app.frame.minY)
        )
        let visibleHeight = control.frame.intersection(viewport).height

        XCTAssertEqual(control.elementType, .button, file: file, line: line)
        XCTAssertTrue(
            control.isHittable,
            "Expected \(control.identifier) to remain independently hittable at Accessibility 5. " +
                "Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.width,
            44,
            "Expected \(control.identifier) to preserve a 44pt semantic width. Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.height,
            44,
            "Expected \(control.identifier) to preserve a 44pt semantic height. Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            visibleHeight,
            44,
            "Expected \(control.identifier) to remain fully visible above the navigation dock. " +
                "Frame=\(control.frame), dockTop=\(dockTop), visible=\(visibleHeight).",
            file: file,
            line: line
        )
    }

    private func assertScheduleWeekItemReachable(
        _ item: XCUIElement,
        in weekGrid: XCUIElement,
        app: XCUIApplication,
        requiresHitTesting: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(item, file: file, line: line)
        assertVisible(weekGrid, file: file, line: line)

        func viewport() -> CGRect {
            let dockTop = ["Tasks", "Schedule", "Weave", "Settings", "tabBar.capture"]
                .compactMap { identifier -> CGFloat? in
                    let control = app.buttons[identifier]
                    guard control.exists, control.isHittable else { return nil }
                    return control.frame.minY
                }
                .min() ?? app.frame.maxY
            let top = max(weekGrid.frame.minY, app.frame.minY)
            let bottom = min(weekGrid.frame.maxY, dockTop - 8)
            return CGRect(
                x: weekGrid.frame.minX,
                y: top,
                width: weekGrid.frame.width,
                height: max(0, bottom - top)
            )
        }

        func isReachable() -> Bool {
            let visibleFrame = item.frame.intersection(viewport())
            let hasVisibleGeometry = visibleFrame.width > 0.5 && visibleFrame.height > 0.5
            return hasVisibleGeometry && (!requiresHitTesting || item.isHittable)
        }

        var geometrySamples: [String] = []
        for _ in 0..<12 {
            let currentViewport = viewport()
            geometrySamples.append(
                "item=\(item.frame), grid=\(weekGrid.frame), viewport=\(currentViewport), " +
                    "hittable=\(item.isHittable)"
            )
            if isReachable() { break }

            let shouldMoveContentUp = item.frame.isEmpty || item.frame.midY > currentViewport.midY
            // The week ScrollView extends behind the floating navigation dock.
            // XCUIElement.swipeUp() derives its start from that obscured full
            // frame, so the dock can receive the gesture. Keep both endpoints
            // inside the actually visible viewport instead.
            let startY = shouldMoveContentUp
                ? currentViewport.maxY - 20
                : currentViewport.minY + 20
            let endY = shouldMoveContentUp
                ? currentViewport.minY + 20
                : currentViewport.maxY - 20
            let start = app.coordinate(withNormalizedOffset: CGVector(
                dx: (currentViewport.midX - app.frame.minX) / app.frame.width,
                dy: (startY - app.frame.minY) / app.frame.height
            ))
            let end = app.coordinate(withNormalizedOffset: CGVector(
                dx: (currentViewport.midX - app.frame.minX) / app.frame.width,
                dy: (endY - app.frame.minY) / app.frame.height
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        XCTAssertGreaterThanOrEqual(
            item.frame.width,
            43.99,
            "Expected \(item.label) to preserve a 44pt semantic width. Samples: " +
                geometrySamples.joined(separator: " | "),
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            item.frame.height,
            43.99,
            "Expected \(item.label) to preserve a 44pt semantic height. Samples: " +
                geometrySamples.joined(separator: " | "),
            file: file,
            line: line
        )
        XCTAssertTrue(
            isReachable(),
            "Expected \(item.label) to remain revealable inside the week grid above the dock. " +
                "Samples: \(geometrySamples.joined(separator: " | ")).",
            file: file,
            line: line
        )
    }

    private func assertSettingsControlReachable(
        _ control: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(control, file: file, line: line)
        scrollToHittable(control, in: app, file: file, line: line)

        let navigationDockTop = ["Tasks", "Schedule", "Weave", "Settings", "tabBar.capture"]
            .compactMap { identifier -> CGFloat? in
                let item = app.buttons[identifier]
                guard item.exists, item.isHittable else { return nil }
                return item.frame.minY
            }
            .min() ?? app.frame.maxY
        let visibleHeight = max(
            0,
            min(control.frame.maxY, navigationDockTop - 8) -
                max(control.frame.minY, app.frame.minY)
        )

        XCTAssertTrue(
            control.isHittable,
            "Expected \(control.identifier) to remain independently hittable at Accessibility 5.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.width,
            44,
            "Expected \(control.identifier) to preserve a 44pt semantic width at Accessibility 5. " +
                "Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.height,
            44,
            "Expected \(control.identifier) to preserve a 44pt semantic height at Accessibility 5. " +
                "Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            visibleHeight,
            44,
            "Expected \(control.identifier) to remain fully revealable above the navigation dock. " +
                "Frame=\(control.frame), dockTop=\(navigationDockTop), visible=\(visibleHeight).",
            file: file,
            line: line
        )
    }

    private func scrollSettingsRouteToHittable(
        _ route: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scrollSurface = app.scrollViews.allElementsBoundByIndex
            .first(where: \.isHittable)
        guard let scrollSurface else {
            XCTFail("Expected Settings to expose a hittable scroll surface.", file: file, line: line)
            return
        }

        func viewport() -> CGRect {
            let dockTop = ["Tasks", "Schedule", "Weave", "Settings", "tabBar.capture"]
                .compactMap { identifier -> CGFloat? in
                    let item = app.buttons[identifier]
                    guard item.exists, item.isHittable else { return nil }
                    return item.frame.minY
                }
                .min() ?? app.frame.maxY
            return CGRect(
                x: scrollSurface.frame.minX,
                y: scrollSurface.frame.minY + 8,
                width: scrollSurface.frame.width,
                height: max(0, min(scrollSurface.frame.maxY, dockTop - 8) - scrollSurface.frame.minY - 8)
            )
        }

        func isReachable() -> Bool {
            let visibleFrame = route.frame.intersection(viewport())
            return route.isHittable && visibleFrame.height >= min(44, route.frame.height)
        }

        var geometrySamples: [String] = []
        for _ in 0..<16 {
            let currentViewport = viewport()
            geometrySamples.append(
                "route=\(route.frame), viewport=\(currentViewport), hittable=\(route.isHittable)"
            )
            if isReachable() { break }

            let shouldMoveContentUp = route.frame.isEmpty || route.frame.midY > currentViewport.midY
            let start = scrollSurface.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: shouldMoveContentUp ? 0.68 : 0.32
            ))
            let end = scrollSurface.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: shouldMoveContentUp ? 0.36 : 0.64
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        XCTAssertTrue(
            isReachable(),
            "Expected \(route.identifier) to become fully reachable above the navigation dock. " +
                "Samples: \(geometrySamples.joined(separator: " | ")).",
            file: file,
            line: line
        )
    }

    private func assertBlockedTimeEditorControlReachable(
        _ control: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let minimumTarget: CGFloat = 44
        let geometryTolerance: CGFloat = 0.01
        // SwiftUI Form exposes its native table as a non-hittable container
        // even while the contained fields and buttons are independently
        // hittable. Use that container for geometry, then synthesize the drag
        // through the application coordinate space.
        let scrollSurface = app.tables.allElementsBoundByIndex
            .first(where: { $0.exists && !$0.frame.isEmpty })
            ?? app.scrollViews.allElementsBoundByIndex
                .first(where: { $0.exists && !$0.frame.isEmpty })
        guard let scrollSurface else {
            XCTFail("Expected the Blocked Time editor to expose a hittable scroll surface.", file: file, line: line)
            return
        }

        func navigationDockTop() -> CGFloat {
            ["Tasks", "Schedule", "Weave", "Settings", "tabBar.capture"]
                .compactMap { identifier -> CGFloat? in
                    let item = app.buttons[identifier]
                    guard item.exists, item.isHittable else { return nil }
                    return item.frame.minY
                }
                .min() ?? app.frame.maxY
        }

        func visibleHeight() -> CGFloat {
            let viewport = CGRect(
                x: scrollSurface.frame.minX,
                y: scrollSurface.frame.minY + 8,
                width: scrollSurface.frame.width,
                height: max(
                    0,
                    min(scrollSurface.frame.maxY, navigationDockTop() - 8) -
                        scrollSurface.frame.minY - 8
                )
            )
            return control.frame.intersection(viewport).height
        }

        var geometrySamples: [String] = []
        for _ in 0..<12 {
            let currentVisibleHeight = visibleHeight()
            geometrySamples.append(
                "control=\(control.frame), scroll=\(scrollSurface.frame), " +
                    "dockTop=\(navigationDockTop()), visible=\(currentVisibleHeight), " +
                    "hittable=\(control.isHittable)"
            )
            if currentVisibleHeight + geometryTolerance >= minimumTarget,
               control.isHittable {
                break
            }

            let shouldMoveContentUp = control.frame.isEmpty ||
                control.frame.midY > scrollSurface.frame.midY
            let startY = scrollSurface.frame.minY + scrollSurface.frame.height *
                (shouldMoveContentUp ? 0.68 : 0.32)
            let endY = scrollSurface.frame.minY + scrollSurface.frame.height *
                (shouldMoveContentUp ? 0.36 : 0.64)
            let normalizedX = (scrollSurface.frame.midX - app.frame.minX) / app.frame.width
            let start = app.coordinate(withNormalizedOffset: CGVector(
                dx: normalizedX,
                dy: (startY - app.frame.minY) / app.frame.height
            ))
            let end = app.coordinate(withNormalizedOffset: CGVector(
                dx: normalizedX,
                dy: (endY - app.frame.minY) / app.frame.height
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        XCTAssertTrue(
            control.exists,
            "Expected \(control.identifier) to materialize while scrolling the Blocked Time form. " +
                "Samples: \(geometrySamples.joined(separator: " | ")).",
            file: file,
            line: line
        )

        XCTAssertGreaterThanOrEqual(
            control.frame.width + geometryTolerance,
            minimumTarget,
            "Expected \(control.identifier) to preserve a 44pt semantic width. " +
                "Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.height + geometryTolerance,
            minimumTarget,
            "Expected \(control.identifier) to preserve a 44pt semantic height. " +
                "Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            visibleHeight() + geometryTolerance,
            minimumTarget,
            "Expected \(control.identifier) to remain fully revealable above the dock. " +
                "Samples: \(geometrySamples.joined(separator: " | ")).",
            file: file,
            line: line
        )
        XCTAssertTrue(
            control.isHittable,
            "Expected \(control.identifier) to remain independently hittable. " +
                "Samples: \(geometrySamples.joined(separator: " | ")).",
            file: file,
            line: line
        )
    }

    private func assertBlockedTimeToolbarControlReachable(
        _ control: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertVisible(control, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            control.frame.width,
            44,
            "Expected \(control.identifier) to preserve a 44pt toolbar width. Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            control.frame.height,
            44,
            "Expected \(control.identifier) to preserve a 44pt toolbar height. Frame=\(control.frame).",
            file: file,
            line: line
        )
        XCTAssertTrue(
            app.frame.contains(control.frame),
            "Expected \(control.identifier) to stay fully within the visible editor toolbar. " +
                "Frame=\(control.frame), app=\(app.frame).",
            file: file,
            line: line
        )
        XCTAssertTrue(
            control.isHittable,
            "Expected \(control.identifier) to remain independently hittable. Frame=\(control.frame).",
            file: file,
            line: line
        )
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func isClearOfNavigationDock() -> Bool {
            guard element.exists, element.isHittable else { return false }

            let dockTop = ["Tasks", "Schedule", "Weave", "Settings", "tabBar.capture"]
                .compactMap { identifier -> CGFloat? in
                    let control = app.buttons[identifier]
                    guard control.exists, control.isHittable else { return nil }
                    return control.frame.minY
                }
                .min() ?? app.frame.maxY

            return element.frame.midY < dockTop - 8
        }

        for _ in 0..<12 {
            if isClearOfNavigationDock() { break }
            app.swipeUp()
        }
        XCTAssertTrue(
            isClearOfNavigationDock(),
            "Expected \(element) to become hittable above the navigation dock",
            file: file,
            line: line
        )
    }

    private func assertVisible(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), file: file, line: line)
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
