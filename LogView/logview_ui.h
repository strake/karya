// Copyright 2013 Evan Laforge
// This program is distributed under the terms of the GNU General Public
// License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

#ifndef __LOGVIEW_UI_H
#define __LOGVIEW_UI_H

#include <string>
#include <FL/Fl_Double_Window.H>
#include <FL/Fl_Group.H>
#include <FL/Fl_Output.H>
#include <FL/Fl_Text_Display.H>
#include <FL/Fl_Text_Buffer.H>


typedef void (*MsgCallback)(int callback_type, const char *);
enum CallbackType {
    cb_click = 1,
    cb_command = 2
};

class TextDisplay : public Fl_Text_Display {
public:
    TextDisplay(int X, int Y, int W, int H) : Fl_Text_Display(X, Y, W, H) {}
    // Make this public.
    int xy_to_position(int x, int y) {
        return Fl_Text_Display::xy_to_position(x, y);
    }
};


class LogView : public Fl_Group {
public:
    LogView(int X, int Y, int W, int H, MsgCallback cb, int max_bytes);
    void resize(int x, int y, int w, int h);
    void append_log(const char *msg, const char *style);
    void clear_logs();
    void set_status(const char *msg, const char *style);
    void set_filter(const char *s) { command.value(s); }

protected:
    virtual int handle(int evt);
private:
    MsgCallback msg_callback;
    Fl_Text_Buffer buffer;
    Fl_Text_Buffer style_buffer;
    Fl_Text_Buffer status_buffer;
    Fl_Text_Buffer status_style_buffer;
    TextDisplay status;
    Fl_Input command;
    TextDisplay display;

    // Unwrapped versions of style_buffer and status_buffer, so they can be
    // rewrapped when the window size changes.
    std::string unwrapped, unwrapped_style;

    void set_status_height(int height);
    static void command_cb(Fl_Widget *w, void *vp);

    // Keep a maximm of this many bytes.
    int max_bytes;
};

class LogViewWindow : public Fl_Double_Window {
public:
    LogViewWindow(int X, int Y, int W, int H, const char *label,
        MsgCallback cb, int max_bytes);
    LogView view;
};

#endif
