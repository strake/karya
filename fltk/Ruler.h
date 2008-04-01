/*
Rulers appear in two places: on a dedicated ruler track, and as an overlay on
an event track.  The former can be implemented as an overlay onto a plain box.
There are some differences though: I may want to disable names for the event
track overlay, and alpha for the ruler track.

*/

#ifndef __RULER_H
#define __RULER_H

#include <utility>
#include <vector>
#include <string>
#include <boost/shared_ptr.hpp>

#include <FL/Fl_Group.H>
#include <FL/Fl_Box.H>

#include "util.h"
#include "config.h"

#include "types.h"
#include "Track.h"

struct Mark {
    Mark(int rank, int width, Color color, const char *name,
            double name_zoom_level, double zoom_level) :
        rank(rank), width(width), color(color), name(name),
        name_zoom_level(name_zoom_level), zoom_level(zoom_level)
    {
        ASSERT(rank >= 0);
    }

    int rank;
    int width;
    Color color;
    // Logically const, but can't be because vector push_back uses assignment.
    std::string name;
    double name_zoom_level;
    double zoom_level;
};

typedef std::vector<std::pair<TrackPos, Mark> > Marklist;
typedef std::vector<boost::shared_ptr<const Marklist> > Marklists;

// Markslists will be drawn in the order they are given, so later marklists
// will draw over earlier ones.
struct RulerConfig {
    RulerConfig(const Marklists &mlists, Color bg, bool show_names,
            bool use_alpha, bool full_width) :
        marklists(mlists), bg(bg), show_names(show_names),
        use_alpha(use_alpha), full_width(full_width)
    {}
    const Marklists marklists;

    // RulerTrackView uses this to set the bg_box, an EventTrack's OverlayRuler
    // doesn't use it.
    const Color bg;

    // So I can share marklists but have different display styles.
    bool show_names;
    bool use_alpha;
    // Always draw marks across the full width of the track.
    bool full_width;
};


class OverlayRuler : public Fl_Group {
public:
    OverlayRuler(const RulerConfig &config) :
        Fl_Group(0, 0, 1, 1), config(config), selections(Config::max_selections)
    {}
    void set_zoom(const ZoomInfo &zoom);
    void set_selection(int selnum, Color c, const Selection &sel);
    TrackPos time_end() const;

    RulerConfig config;
protected:
    void draw();

private:
    void damage_range(TrackPos start, TrackPos end);
    void draw_marklists();
    void draw_mark(int offset, const Mark &mark);
    void draw_selections();
    std::vector<std::pair<Color, Selection> > selections;

    // This area needs to be redrawn.
    Rect damaged_area;
    // Widget should be shifted by this many pixels timewise.  For scrolling.
    int shift;
    ZoomInfo zoom;
};


class RulerTrackView : public TrackView {
public:
    RulerTrackView(const RulerConfig &config);
    virtual Fl_Box &title_widget();
    virtual void set_zoom(const ZoomInfo &zoom) { ruler.set_zoom(zoom); }
    virtual void set_selection(int selnum, Color c, const Selection &sel) {
        ruler.set_selection(selnum, c, sel);
    }
    virtual TrackPos time_end() const { return ruler.time_end(); }

protected:
    // void draw();

private:
    // If created, this is owned by a Fl_Group, which deletes it.
    Fl_Box *title_box;
    OverlayRuler ruler;
        Fl_Box bg_box;
};

#endif
