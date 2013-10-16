// Copyright 2013 Evan Laforge
// This program is distributed under the terms of the GNU General Public
// License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

#include <FL/Fl.H>

#include "f_util.h"
#include "config.h"
#include "input_util.h"

#include "MsgCollector.h"
#include "WrappedInput.h"


enum {
    // Account for input widget padding.
    vertical_padding = 3,
    // The input widget has a few pixels of padding, so I should wrap a little
    // conservatively.
    horizontal_padding = 5
};


WrappedInput::WrappedInput(int X, int Y, int W, int H) :
    Fl_Multiline_Input(X, Y, W, H)
{
    this->color(FL_WHITE);
    this->textsize(Config::font_size::input);
    this->box(FL_THIN_DOWN_BOX);
    // FL_WHEN_RELEASE is documented as firing whenever focus leaves the input.
    // But that's not true, it doesn't fire if the text hasn't changed.
    // So I have to call 'do_callback' on FL_UNFOCUS myself.
    this->when(0);
}


static void
invoke_callback(void *vp)
{
    Fl_Widget *self = static_cast<Fl_Widget *>(vp);
    self->do_callback();
}

void
WrappedInput::resize(int x, int y, int w, int h) // , bool no_wrap)
{
    int old_w = this->w();
    Fl_Multiline_Input::resize(x, y, w, h);
    // Only a horizontal change can affect wrapping.  Since a rewrap can cause
    // a vertical resize, this also avoids recursion.
    if (this->w() != old_w) {
        // If I call it synchronously, widgets don't resize properly.  As far
        // as I can tell, this is due to re-entrantly calling resize functions.
        // Using a timeout fixes the problem, but only when the mouse goes up,
        // which is a bit ugly.
        if (this->wrap_text())
            Fl::add_timeout(0, invoke_callback, this);
    }
}

void
WrappedInput::set_text(const char *text)
{
    this->value(text);
    wrap_text();
    do_callback();
}


const char *
WrappedInput::get_text() const
{
    static std::string unwrapped;

    unwrapped = this->value();
    for (size_t i = 0; i < unwrapped.length(); i++) {
        if (unwrapped[i] == '\n')
            unwrapped[i] = ' ';
    }
    return unwrapped.c_str();
}


int
WrappedInput::text_height() const
{
    int newlines = 0;
    for (const char *text = this->value(); *text; text++) {
        if (*text == '\n')
            newlines++;
    }
    fl_font(Config::font, Config::font_size::input);
    return (newlines + 1) * fl_height() + vertical_padding;
}


int
WrappedInput::handle(int evt)
{
    // This is a crazy delicate mess because I have to apply my own key
    // bindings but fall back on the Fl_Multiline_Input ones otherwise.
    if (evt == FL_KEYUP) {
        // If this is an edit input created in response to a keystroke, it gets
        // focus immediately and the keyup will wind up here.  So I have to
        // make sure the MsgCollector gets it.
        MsgCollector::get()->key_up(Fl::event_key());
    }
    if (input_util::should_ignore(evt))
        return 0;
    bool handled = input_util::handle(this, evt);
    if (!handled) {
        handled = Fl_Multiline_Input::handle(evt);
        if (evt == FL_KEYDOWN) {
            this->wrap_text();
            this->do_callback();
        }
    }
    if (evt == FL_UNFOCUS) {
        if (input_util::strip_value(this))
            this->wrap_text();
        this->do_callback();
    }
    return handled;
}


static char *
find_space(const char *s, char *end)
{
    char *space = strchr(s, ' ');
    if (space == NULL)
        space = end;
    char *nl = strchr(s, '\n');
    if (nl == NULL)
        nl = end;
    return std::min(space, nl);
}

bool
WrappedInput::wrap_text()
{
    // Just for memory management.
    std::auto_ptr<char> text_ptr(strdup(this->value()));
    char *text = &*text_ptr;
    char *end = text + strlen(text);
    bool changed = false;

    char *start_of_line = text;
    char *prev_space = NULL;
    int max_width = this->w() - horizontal_padding;

    // DEBUG("wrap '" << text << "' " << (end - text) << " w " << max_width);

    // Yes, it's yet another wrapping algorithm.  Fortunately, this one is
    // much simpler than the one in SymbolTable.
    // * prev_space ^ space | start_of_line
    //      |
    // aaa bbb ccc
    // *  ^             < max_width
    // |  *   ^         > max_width
    // aaa\n
    // bbb ccc
    // |* ^
    // |  *   ^
    // aaa
    // bbb
    // ccc
    // |* ^
    //
    //    |
    // aaabbbccc abc
    // |*       ^
    // |        ^   *
    //          |
    fl_font(Config::font, Config::font_size::input);
    for (;;) {
        // +1 to skip the space.
        char *space = find_space(
            prev_space ? prev_space + 1 : start_of_line, end);
        double w = fl_width(start_of_line, space - start_of_line);
        // DEBUG("space " << space - text << " w " << w << " < " << max_width);
        if (w > max_width) {
            // One unbreakable word is longer than max_width, so I have to
            // break at the soonest space.
            if (!prev_space)
                prev_space = space;
            // Ran out of text!
            if (!*prev_space)
                break;

            if (*prev_space == ' ') {
                // DEBUG("space to nl: " << prev_space - text);
                *prev_space = '\n';
                changed = true;
            }
            start_of_line = prev_space + 1;
            prev_space = NULL;
        } else {
            if (prev_space && *prev_space == '\n') {
                // DEBUG("nl to space: " << prev_space - text);
                *prev_space = ' ';
                changed = true;
            }
            prev_space = space;
            // Ran out of text with room to spare.
            if (!*prev_space)
                break;
        }
    }

    if (changed)
        this->value(text);
    return changed;
}