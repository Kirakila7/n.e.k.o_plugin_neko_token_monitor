#include <assert.h>
#include <stdio.h>
#include "pause-sequence.h"

static void focus_before_press(void) {
    CatFoodPauseSequence s = {0};
    assert(CatFoodPauseNext(&s, 10, true, true, false) == CatFoodPausePrepare);
    CatFoodPausePrepared(&s, 10);
    assert(CatFoodPauseNext(&s, 10.44, true, true, false) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 10.5, true, true, false) == CatFoodPausePress);
    assert(CatFoodPauseNext(&s, 10.6, false, true, false) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 11.21, false, true, false) == CatFoodPausePrepare);
    assert(s.attempts == 0);
}

static void accepted_without_transition_refocuses(void) {
    CatFoodPauseSequence s = {0};
    CatFoodPausePrepared(&s, 10);
    CatFoodPausePressed(&s, 10.5, true);
    assert(CatFoodPauseNext(&s, 11.99, true, true, false) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 12.01, true, true, false) == CatFoodPausePrepare);
    assert(s.attempts == 1 && s.accepted);
    CatFoodPausePrepared(&s, 12.01);
    assert(CatFoodPauseNext(&s, 12.1, true, true, false) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 12.6, true, true, false) == CatFoodPauseReveal);
    CatFoodPauseRevealed(&s, 12.6);
    assert(CatFoodPauseNext(&s, 12.8, true, true, false) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 13.1, true, true, false) == CatFoodPausePress);
}

static void delayed_confirmation_and_flicker(void) {
    CatFoodPauseSequence s = {0};
    CatFoodPausePrepared(&s, 10);
    CatFoodPausePressed(&s, 10.5, true);
    assert(CatFoodPauseNext(&s, 11.4, true, false, true) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 12.5, true, false, true) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 12.61, true, false, true) == CatFoodPauseConfirmed);
    assert(s.attempts == 1);
    s = (CatFoodPauseSequence){0};
    assert(CatFoodPauseNext(&s, 20, true, false, true) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 21, true, true, true) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 21.1, true, false, true) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 22.31, true, false, true) == CatFoodPauseConfirmed);
    assert(s.attempts == 0); /* An already-paused model must not be toggled. */
}

static void bounded_failure_and_control_discovery(void) {
    CatFoodPauseSequence s = {0};
    double t = 10;
    for (unsigned n = 0; n < 4; n++) {
        assert(CatFoodPauseNext(&s, t, true, true, false) == CatFoodPausePrepare);
        CatFoodPausePrepared(&s, t);
        double pressAt=t+.5;
        if(n){
            assert(CatFoodPauseNext(&s, pressAt, true, true, false) == CatFoodPauseReveal);
            CatFoodPauseRevealed(&s, pressAt);pressAt+=.5;
        }
        assert(CatFoodPauseNext(&s, pressAt, true, true, false) == CatFoodPausePress);
        CatFoodPausePressed(&s, pressAt, true);
        assert(CatFoodPauseNext(&s, pressAt+1.4, true, true, false) == CatFoodPauseWait);
        if (n == 3) {
            assert(CatFoodPauseNext(&s, pressAt+1.6, true, true, false) == CatFoodPauseExhausted);
            assert(s.exhausted && s.attempts == 4);
        }
        t=pressAt+1.7;
    }
    s = (CatFoodPauseSequence){0};
    CatFoodPausePrepared(&s, 30);
    assert(CatFoodPauseNext(&s, 30.5, true, false, false) == CatFoodPauseReveal);
    assert(s.attempts == 0 && !s.exhausted);
    CatFoodPausePressed(&s, 31, false);
    assert(CatFoodPauseNext(&s, 31.5, true, true, false) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 31.61, true, true, false) == CatFoodPausePrepare);
}

static void ignored_press_requires_reveal_before_recovery(void) {
    CatFoodPauseSequence s = {0};
    CatFoodPausePrepared(&s, 10);
    CatFoodPausePressed(&s, 10.5, true);
    assert(CatFoodPauseNext(&s, 12.1, true, true, false) == CatFoodPausePrepare);
    CatFoodPausePrepared(&s, 12.1);
    assert(CatFoodPauseNext(&s, 12.6, true, true, false) == CatFoodPauseReveal);
    /* A stale label alone cannot bypass rediscovery on an unconfirmed retry. */
    assert(CatFoodPauseNext(&s, 12.7, true, true, false) == CatFoodPauseReveal);
    CatFoodPauseRevealed(&s, 12.7);
    assert(CatFoodPauseNext(&s, 13.2, true, true, false) == CatFoodPausePress);
    CatFoodPausePressed(&s, 13.2, true);
    assert(CatFoodPauseNext(&s, 13.6, true, false, true) == CatFoodPauseWait);
    assert(CatFoodPauseNext(&s, 14.9, true, false, true) == CatFoodPauseConfirmed);
    assert(s.attempts == 2 && !s.exhausted);
}

static void missing_controls_cancel_without_any_press(void) {
    CatFoodPauseSequence s = {0};
    assert(CatFoodPauseNext(&s, 0, true, false, false) == CatFoodPausePrepare);
    CatFoodPausePrepared(&s, 0);
    assert(CatFoodPauseNext(&s, 2.99, true, false, false) == CatFoodPauseReveal);
    assert(CatFoodPauseNext(&s, 3, true, false, false) == CatFoodPauseExhausted);
    assert(s.missing && s.exhausted && s.attempts == 0);
    assert(CatFoodPauseNext(&s, 4, true, true, false) == CatFoodPauseExhausted);
    s = (CatFoodPauseSequence){0};
    CatFoodPauseNext(&s, 10, true, false, false);
    CatFoodPausePrepared(&s, 10);
    assert(CatFoodPauseNext(&s, 12, true, true, false) == CatFoodPausePress);
    assert(!s.missing && !s.exhausted);
    CatFoodPauseNext(&s, 20, true, false, false);
    assert(CatFoodPauseNext(&s, 22.9, true, false, false) != CatFoodPauseExhausted);
    assert(CatFoodPauseNext(&s, 23, true, false, false) == CatFoodPauseExhausted);
}

int main(void) {
    focus_before_press();
    accepted_without_transition_refocuses();
    delayed_confirmation_and_flicker();
    bounded_failure_and_control_discovery();
    ignored_press_requires_reveal_before_recovery();
    missing_controls_cancel_without_any_press();
    puts("PASS: focus before click, accepted-but-unconfirmed recovery, delayed/flickering state, no return toggle, bounded retries, hidden controls and reset");
    return 0;
}
