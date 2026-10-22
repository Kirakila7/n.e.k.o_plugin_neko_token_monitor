#ifndef CATFOOD_PAUSE_SEQUENCE_H
#define CATFOOD_PAUSE_SEQUENCE_H

#include <stdbool.h>

typedef enum {
    CatFoodPauseWait, CatFoodPausePrepare, CatFoodPauseReveal,
    CatFoodPausePress, CatFoodPauseConfirmed, CatFoodPauseExhausted
} CatFoodPauseAction;

typedef struct {
    unsigned attempts;
    bool prepared, pending, accepted, returnSeen, exhausted, reacquired, missing;
    double preparedAt, pressedAt, returnSince, missingSince;
} CatFoodPauseSequence;

/* Readiness and the return control are observations, not AXPress acknowledgements.
   Keep a delayed transition free of extra clicks and refocus after an ignored one. */
static inline CatFoodPauseAction CatFoodPauseNext(CatFoodPauseSequence *s, double now,
                                                bool ready, bool goodbye, bool returned) {
    if (s->exhausted) return CatFoodPauseExhausted;
    if (returned && !goodbye) {
        s->missing = false;
        if (!s->returnSeen) { s->returnSeen = true; s->returnSince = now; }
        return now - s->returnSince >= 1.2 ? CatFoodPauseConfirmed : CatFoodPauseWait;
    }
    s->returnSeen = false;
    /* Contradictory accessibility labels can occur during a redraw. Never
       press a toggle while a return control is also exposed. */
    if (returned) return CatFoodPauseWait;
    if (!goodbye) {
        if (!s->missing) { s->missing = true; s->missingSince = now; }
        if (now - s->missingSince >= 3.0) {
            s->exhausted = true;
            return CatFoodPauseExhausted;
        }
    } else s->missing = false;
    if (s->pending) {
        if (now - s->pressedAt < (s->accepted ? 1.5 : 0.6)) return CatFoodPauseWait;
        s->pending = false;
        s->prepared = false;
        if (s->attempts >= 4) { s->exhausted = true; return CatFoodPauseExhausted; }
    }
    if (!s->prepared) return CatFoodPausePrepare;
    if (now - s->preparedAt < 0.45) return CatFoodPauseWait;
    if (!ready) {
        if (now - s->preparedAt < 1.2) return CatFoodPauseWait;
        s->prepared = false;
        return CatFoodPausePrepare;
    }
    if (!s->reacquired) return CatFoodPauseReveal;
    return goodbye ? CatFoodPausePress : CatFoodPauseReveal;
}

static inline void CatFoodPausePrepared(CatFoodPauseSequence *s, double now) {
    s->prepared = true;
    s->pending = false;
    s->accepted = false;
    s->reacquired = s->attempts == 0;
    s->preparedAt = now;
}

static inline void CatFoodPauseRevealed(CatFoodPauseSequence *s, double now) {
    s->reacquired = true;
    s->preparedAt = now;
}

static inline void CatFoodPausePressed(CatFoodPauseSequence *s, double now, bool accepted) {
    s->attempts++;
    s->pending = true;
    s->accepted = accepted;
    s->pressedAt = now;
}
#endif
