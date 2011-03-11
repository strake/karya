# TODO BUGS
# - .depend needs 'touch .depend' to bootstrap.
# - All hs depends on build/hspp though none state that.  So 'make build/hspp'
#	is also necessary for bootstrap.
#
# The situation with flags is getting out of control.  Problems:
#
# - seq, test_core_midi need MIDI_LIBS
#
# - seq, test_block, logview, test_logview, browser, test_browser need fltk
#
# - hsc2hs needs the same flags the apps that the generated files will need
# (practically, it just means LIBFLTK), but hsc2hs does't accept flags in the
# same format as gcc.
# Fixable as soon as I can get rid of -m I think.
#
# - tests and profiles are separate targets and require different flags
#
# - ghc generates only 32 bit, but new OS X gcc defaults to 64 bit, so I have
# to pass -m32 to gcc and -optc-m32 etc. to ghc.
# Might be fixable in newer ghc, but I might want 32 bit anyway.

### c++ flags

CXX_DEBUG := -ggdb
CXX_OPT := -O2
OPT := $(CXX_DEBUG)

# Global -D flags for all C compilers.
DEFINE := -DMAC_OS_X_VERSION_MAX_ALLOWED=1060 \
	-DMAC_OS_X_VERSION_MIN_REQUIRED=1050

# Current ghc only compiles in 32 bit mode.  Newer ghc compiles 64 bit I think,
# but I'm afraid it will take up much more memory.
ARCH := -m32

MIDI_LIBS := -framework CoreFoundation -framework CoreMIDI -framework CoreAudio
CINCLUDE := -Ifltk -I.

# Flags for all versions.
FLTK_LD := -lpthread -framework Carbon -framework ApplicationServices \
    -framework AudioToolbox
LIBFLTK_D := -D_THREAD_SAFE -D_REENTRANT

# vanilla fltk
LIBFLTK_INC := -I/usr/local/include -I/usr/local/include/FL/images
LIBFLTK_LD := -L/usr/local/lib -lfltk

# cocoa fltk
LIBFLTK_1_3_LD := /usr/local/src/fltk-dev/fltk-1.3/lib/libfltk.a \
	-framework Cocoa
LIBFLTK_1_3_INC := -I/usr/local/src/fltk-dev/fltk-1.3/

FLTK_CXX := $(LIBFLTK_1_3_INC) $(LIBFLTK_D)
CXXFLAGS := $(FLTK_CXX) $(DEFINE) $(OPT) $(CINCLUDE) $(ARCH) -Wall

LDFLAGS := $(LIBFLTK_1_3_LD) $(FLTK_LD) $(ARCH)


### ghc flags

# Turn this on to optimize the main app.
# SEQ_OPT := -O2
# INTERPRETER_HINT links the hint library to provide a haskell interpreter.  It
# adds about 10s to linking time and I often don't need it, so here's a switch
# for it.
# INTERPRETER_PLUGINS links the plugins library for a haskell interpreter.
# It links faster than hint but leaks memory.  And it's broken.
SEQ_INTERPRETER := -DINTERPRETER_HINT

# without hint: make -j3 build/seq  9.06s user 1.17s system 99% cpu 10.333 total
# with hint: make -j3 build/seq  18.89s user 1.90s system 98% cpu 21.125 total
SEQ_FLAGS := $(SEQ_INTERPRETER) $(SEQ_OPT)


# Flags to compile the tests.
HTEST := -fhpc

# Flags to compile the profiles.
HPROFILE := -prof -auto-all -caf-all -O2

# HLDFLAGS := $(LDFLAGS)
# TODO ghc doesn't accept -m32 like gcc and ld do.
# GHC 6.12 adds these flags already, but I think 7 doesn't.
HLDFLAGS := $(LIBFLTK_1_3_LD) $(FLTK_LD) -optc-m32 -opta-m32 -optl-m32

GHC := ghc-6.12.3
# Used by haddock to find system docs, but it doesn't work anyway.
# TODO Fix this someday.
GHC_LIB := /Library/Frameworks/GHC.framework/Versions/612/usr/lib/ghc-6.12.3

# hspp adds filename and lineno to various logging and testing functions.
HFLAGS := -threaded -W -fwarn-tabs \
	$(CINCLUDE) -i../lib -pgmc g++ -pgml g++ \
	-optc -ggdb -optl -ggdb \
	-F -pgmF build/hspp

### misc variables

# Directory for built binaries.
BUILD := build
TBUILD := $(BUILD)/test
PBUILD := $(BUILD)/profile

BUNDLE = tools/make_bundle $@

### objects and binaries

FLTK_OBJS := Block.o TrackTile.o Track.o Ruler.o EventTrack.o MoveTile.o \
	Event.o P9Scrollbar.o SimpleScroll.o SeqInput.o MsgCollector.o \
	SkeletonDisplay.o SymbolTable.o \
	f_util.o alpha_draw.o types.o config.o
FLTK_OBJS := $(addprefix fltk/, $(FLTK_OBJS))

BINARIES := $(addprefix $(BUILD)/, seq send repl browser make_db dump update \
	logview timer logcat)
TEST_BINARIES := $(addprefix $(BUILD)/, test_block test_logview test_browser \
		test_core_midi) \
	$(TBUILD)/RunTests


### targets

# Run the things I think should be run before checkin.
.PHONY: checkin
checkin:
	tools/make_all $(BUILD)/seq $(BUILD)/browser $(BUILD)/logview \
		$(PBUILD)/RunProfile tests

# Compile Everything.
.PHONY: all
all:
	tools/make_all $(BINARIES) $(TEST_BINARIES)

.PHONY: dep
dep: build/fixdeps
	g++ -MM $(CXXFLAGS) */*.cc | build/fixdeps >.depend
	printf '\n\n# hsc deps:\n' >>.depend
	tools/hscdeps.py $(CINCLUDE) -I$(GHC_LIB)/include */*.hsc >>.depend

include .depend

build/fixdeps: tools/fixdeps.hs
	$(GHC) -o $@ $^

build/hspp: tools/hspp.hs
	$(GHC) -O2 --make -W -o $@ $^

.PHONY: clean
clean:
	rm -f `find . -name '*.o' -or -name '*.hi' -or -name '*.pyc'` \
		fltk/fltk.a \
		$(UI_HS) $(PORTMIDI_HS) $(LOGVIEW_HS) $(BROWSER_HS) haddock/*  \
		hpc/* seq_language
	rm -rf $(BUILD)/* .hpc

fltk/fltk.a: $(FLTK_OBJS)
	ar -rs $@ $^

$(BUILD)/test_block: fltk/test_block.o fltk/fltk.a
	$(CXX) -o $@ $^ $(LDFLAGS)
	$(BUNDLE)

UI_HSC := $(wildcard Ui/*.hsc)
UI_HS := $(UI_HSC:hsc=hs)
UI_OBJS := Ui/c_interface.o

COREMIDI_OBJS := Midi/core_midi.o

ALL_HS = $(shell tools/all_hs.py)

### main app

SEQ_CMDLINE = $(GHC) $(HFLAGS) \
	--make -main-is App.Main App/Main.hs \
	$(UI_OBJS) $(COREMIDI_OBJS) fltk/fltk.a $(MIDI_LIBS) $(HLDFLAGS)

# PHONY convinces make to always run ghc, which figures out deps on its own
.PHONY: $(BUILD)/seq
$(BUILD)/seq: $(UI_HS) $(UI_OBJS) $(COREMIDI_OBJS) fltk/fltk.a
	$(SEQ_CMDLINE) $(SEQ_FLAGS) -o $@
	$(BUNDLE) doc/seq.icns

### midi

.PHONY: $(BUILD)/test_core_midi
$(BUILD)/test_core_midi: $(UI_HS) $(COREMIDI_OBJS)
	$(GHC) $(HFLAGS) --make \
		-main-is Midi.TestCoreMidi Midi/TestCoreMidi.hs -o $@ \
		$(COREMIDI_OBJS) $(MIDI_LIBS)

### repl

.PHONY: $(BUILD)/send
$(BUILD)/send: App/Send.hs
	$(GHC) $(HFLAGS) --make $^ -o $@
.PHONY: $(BUILD)/repl
$(BUILD)/repl: App/Repl.hs
	$(GHC) $(HFLAGS) --make $^ -o $@ $(HLDFLAGS)

### saved state

.PHONY: $(BUILD)/dump
$(BUILD)/dump: App/Dump.hs
	$(GHC) $(HFLAGS) --make $^ -o $@

.PHONY: $(BUILD)/update
$(BUILD)/update: App/Update.hs
	$(GHC) $(HFLAGS) --make $^ -o $@

### logview

LOGVIEW_OBJ = LogView/LogView.hs LogView/LogViewC.hs \
	LogView/interface.o LogView/logview_ui.o
LOGVIEW_HS = LogView/LogViewC.hs

.PHONY: $(BUILD)/logview
# depend on Color because of Util.Log -> Peform.Warning import grossness
# someday I should remove that
$(BUILD)/logview: $(LOGVIEW_OBJ) Ui/Color.hs
	$(GHC) $(HFLAGS) --make $^ -o $@ $(HLDFLAGS)
	$(BUNDLE)

$(BUILD)/test_logview: LogView/test_logview.o LogView/logview_ui.o fltk/f_util.o
	$(CXX) -o $@ $^ $(LDFLAGS)
	$(BUNDLE)

### log util

.PHONY: $(BUILD)/timer
$(BUILD)/timer: LogView/Timer.hs
	$(GHC) $(HFLAGS) --make -main-is LogView.Timer $^ -o $@

.PHONY: $(BUILD)/logcat
$(BUILD)/logcat: LogView/LogCat.hs
	$(GHC) $(HFLAGS) --make $^ -o $@

### browser

BROWSER_OBJ = Instrument/Browser.hs \
	Instrument/interface.o Instrument/browser_ui.o \
	Util/fltk_interface.o
BROWSER_HS = Instrument/BrowserC.hs

.PHONY: $(BUILD)/browser
$(BUILD)/browser: $(BROWSER_OBJ) $(BROWSER_HS)
	$(GHC) $(HFLAGS) --make $^ -o $@ $(HLDFLAGS)
	$(BUNDLE)

$(BUILD)/test_browser: Instrument/test_browser.o Instrument/browser_ui.o \
		fltk/f_util.o
	$(CXX) -o $@ $^ $(LDFLAGS)
	$(BUNDLE)

.PHONY: $(BUILD)/make_db
$(BUILD)/make_db: Instrument/MakeDb.hs
	$(GHC) $(HFLAGS) --make $^ -o $@
.PHONY: sense
sense:
	@echo 'Nevairrrr!'

### doc

ALL_HSC := $(patsubst %.hsc, %.hs, $(filter %.hsc, $(ALL_HS)))

.PHONY: doc
doc: $(ALL_HSC)
	@# Unless there's some way to tell firefox to go to a certain line in
	@# a file, I can't use --source-entity without something like hscolour.
	haddock --html -B $(GHC_LIB) --source-module="../%F" -o haddock \
		$(shell tools/all_hs.py notest nomain hsc_as_hs)

### tests ###

TEST_CMDLINE = $(GHC) $(HFLAGS) --make -DTESTING \
	$(UI_OBJS) $(COREMIDI_OBJS) fltk/fltk.a $(MIDI_LIBS) $(HLDFLAGS)

# Compiles with -odir and -hidir into $(TBUILD)/ because they are compiled with
# different flags.
$(TBUILD)/RunTests.hs: $(ALL_HS)
	test/generate_run_tests.py $@ $(filter %_test.hs, $(ALL_HS))
$(TBUILD)/RunTests: $(TBUILD)/RunTests.hs $(UI_HS) $(UI_OBJS) \
		$(COREMIDI_OBJS) fltk/fltk.a
	$(TEST_CMDLINE) -i -i$(TBUILD):. -odir $(TBUILD) -hidir $(TBUILD) \
		$(TBUILD)/RunTests.hs $(HTEST) -o $@
	rm -f *.tix # this sticks around and breaks hpc
	rm -f test.output # this gets reset on each new test run

$(PBUILD)/RunProfile.hs: $(ALL_HS)
	test/generate_run_tests.py $@ $(filter %_profile.hs, $(ALL_HS))

.PHONY: $(PBUILD)/RunProfile
$(PBUILD)/RunProfile: $(PBUILD)/RunProfile.hs $(UI_HS) $(UI_OBJS) \
		$(COREMIDI_OBJS) fltk/fltk.a
	$(TEST_CMDLINE) -i -i$(PBUILD):. -odir $(PBUILD) -hidir $(PBUILD) \
		$(PBUILD)/RunProfile.hs -o $@ $(HPROFILE)

.PHONY: $(PBUILD)/seq
$(PBUILD)/seq: $(UI_HS) $(UI_OBJS) $(COREMIDI_OBJS) fltk/fltk.a
	$(SEQ_CMDLINE) -i -i$(PBUILD):. -odir $(PBUILD) -hidir $(PBUILD) \
		$(HPROFILE) -o $@
	$(BUNDLE) doc/seq.icns

.PHONY: profile
profile: $(PBUILD)/RunProfile
	tools/summarize_profile.py

.PHONY: tests
tests: $(TBUILD)/RunTests
	test/run_tests $^ auto-

.PHONY: interactive
interactive: $(TBUILD)/RunTests
	test/run_tests $^ interactive-

### misc ###

tags: $(ALL_HS)
	hasktags --ignore-close-implementation --ctags $^
	sort tags >tags.sorted
	(echo -e '!_TAG_FILE_SORTED\t1\t ~'; cat tags.sorted) >tags
	rm tags.sorted

# TODO hsc2hs can't use the CXXFLAGS since it chokes on flags like -m.  So I
# have to break it out into its components which is brittle.  Can I patch
# hsc2hs to take a --cflags arg and include all flags literally?
%.hs: %.hsc
	hsc2hs -c g++ --cflag -Wno-invalid-offsetof $(CINCLUDE) $(FLTK_CXX) \
		$(DEFINE) --cflag=$(ARCH) $(PORTMIDI_I) $<
	@# hsc2hs stil includes INCLUDE but ghc 6.12 doesn't like that
	grep -v INCLUDE $@ >$@.tmp
	mv $@.tmp $@


### portmidi ###
# I'm not using this now, but may use it again in the future

# PORTMIDI := /usr/local/src/portmedia/portmidi/trunk
# PORTMIDI_I := -Ifltk -I$(PORTMIDI)/pm_common -I$(PORTMIDI)/porttime -I.
#
# PORTMIDI_HSC := $(wildcard Midi/*.hsc)
# PORTMIDI_HS := $(PORTMIDI_HSC:hsc=hs)
#
# .PHONY: $(BUILD)/test_portmidi
# $(BUILD)/test_portmidi: Midi/PortMidi.hs $(UI_HS)
# 	$(GHC) $(HFLAGS) --make \
# 		-main-is Midi.TestMidi Midi/TestMidi.hs $(MIDI_LIBS) -o $@
