// Copyright 2017 Evan Laforge
// This program is distributed under the terms of the GNU General Public
// License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

#pragma once

#include <memory>
#include <stdlib.h>
#include <string.h>
#include <utility>
#include <vector>

#include <faust/gui/CInterface.h>

#include "fltk/util.h" // TODO for ASSERT


// A wrapper around faust's generated dsp class.
//
// This is so I can implement getState and putState as directly serializing the
// dsp state.  Since the faust C++ output has virtual methods, I think I can't
// directly serialize it without some scary hacks to avoid overwriting the
// vtable.  So I use the C output, which provides the entire state as a plain
// struct, and then wrap it back up as an object.  This is a bit awkward, but
// it lets me fix some other problems with faust's generated C++, namely that
// you have to instantiate the class and allocate all its memeory just to get
// number of inputs and outputs and metadata.
class Patch {
public:
    // This is only ever used as a pointer to the internal state.  I could use
    // a template to pass it to the faust-generated functions in a typesafe
    // way, but since I have to put all the Patches in an array, I have to
    // cast away the safety at some point, so it might as well be here.
    //
    // I don't know if there are alignment restrictions on the state pointer,
    // but faust just has ints and floats, so a double should definitely be
    // aligned enough for that.  Actually I think this doesn't matter, since
    // calloc() below is establishing the alignment, and it's explicitly
    // universal.
    struct State { double x; };
    typedef void (*Initialize)(State *, int);
    typedef void (*Metadata)(MetaGlue *);
    typedef void (*UiMetadata)(UIGlue *);
    // TODO input is treated as const, I should fix faust's generated c++.
    typedef void (*Compute)(State *state, int, const float **, float **);

    Patch(const char *name, size_t size, int inputs, int outputs,
            Initialize initialize, Metadata metadata, UiMetadata uiMetadata,
            Compute compute_) :
        name(name), size(size), inputs(inputs), outputs(outputs),
        state(nullptr),
        metadata(metadata), uiMetadata(uiMetadata), initialize(initialize),
        compute_(compute_)
    {}
    ~Patch() {
        delete state;
    }

    Patch *allocate(int srate) const {
        Patch *p = new Patch(
            name, size, inputs, outputs, initialize, metadata, uiMetadata,
            compute_);
        p->state = static_cast<State *>(calloc(1, size));
        ASSERT(p->state != nullptr);
        p->initialize(p->state, srate);
        return p;
    }

    typedef std::vector<std::pair<const char *, const char *>> Pairs;
    Pairs getMetadata() const;

    struct Widget {
        Widget(const char *label, FAUSTFLOAT *value, bool boolean,
                FAUSTFLOAT init = 0, FAUSTFLOAT min = 0, FAUSTFLOAT max = 0,
                FAUSTFLOAT step = 0)
            : label(label), value(value), boolean(boolean), init(init),
                min(min), max(max), step(step)
            {}
        const char *label;
        FAUSTFLOAT *value;
        bool boolean;
        FAUSTFLOAT init, min, max, step;
    };

    std::vector<Widget> getUiMetadata() const;

    size_t getState(const State **p) const {
        *p = state;
        return size;
    }
    void putState(const State *p) {
        memcpy(state, p, size);
    }

    void compute(int count, const float **inputs, float **outputs) {
        ASSERT(state != nullptr);
        compute_(state, count, inputs, outputs);
    }

    const char *name;
    const size_t size;
    const int inputs, outputs;
private:
    State *state;
    Metadata metadata;
    UiMetadata uiMetadata;
    Initialize initialize;
    Compute compute_;
};
