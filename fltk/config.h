// This has constants which are not worth putting under host control by putting
// in a *Config class.
#ifndef __CONFIG_H
#define __CONFIG_H

#include <FL/Enumerations.H>
#include "util.h"
#include "types.h"

namespace Config {

enum {
    // Color as a word so haskell can get to it easily.
    abbreviation_color_word = 0x0000ff00
};

// This color signifies that some content has been omitted due to lack of
// space.
extern const Color abbreviation_color;

// Mark the playing end of events with this.
extern const Color event_trigger_color;

// Default sizes for a BlockView.
//
// Previously these were configurable from haskell in the same way as
// BlockModelConfig, but it didn't seem useful so they're hardcoded now.
namespace View {
    enum {
        block_title_height = 20,
        track_title_height = 20,
        skel_height = 16,
        sb_size = 5,
        status_size = 16
    };
};

enum {
    max_selections = 6,
    font = FL_HELVETICA
};

namespace font_size {
    enum {
        input = 12,
        ruler = 9,
        track_status = 12,
        pitch_signal = 9
    };
};

}

#endif
