-- | Collect the various calls into one place.
module Derive.Call.All where
import qualified Data.Map as Map

import qualified Derive.Call.Block as Block
import qualified Derive.Call.Control as Control
import qualified Derive.Call.Echo as Echo
import qualified Derive.Call.Idiom.String as String
import qualified Derive.Call.Note as Note
import qualified Derive.Call.NoteTransformer as NoteTransformer
import qualified Derive.Call.Ornament as Ornament
import qualified Derive.Call.Pitch as Pitch
import qualified Derive.Call.Post.Reverse as Reverse
import qualified Derive.Call.Rambat as Rambat
import qualified Derive.Call.Sekar as Sekar
import qualified Derive.Call.Trill as Trill
import qualified Derive.Derive as Derive
import qualified Derive.TrackLang as TrackLang


scope :: Derive.Scope
scope = Derive.Scope note_lookups control_lookups (make_lookup pitch_calls)
    (make_lookup val_calls)

-- | Note calls are special in that they look for a block with that name first.
note_lookups :: Derive.ScopeType Derive.NoteCall
note_lookups = Derive.empty_scope_type { Derive.stype_builtin =
    [Block.lookup_note_block, Derive.make_lookup note_calls] }

-- | Well ok, control calls are special too.
control_lookups :: Derive.ScopeType Derive.ControlCall
control_lookups = Derive.empty_scope_type
    { Derive.stype_builtin =
        -- [ Control.hex_literal
        [ Block.lookup_control_block
        , Derive.make_lookup control_calls
        ]
    }

make_lookup :: Map.Map TrackLang.CallId call -> Derive.ScopeType call
make_lookup cmap = Derive.empty_scope_type
    { Derive.stype_builtin = [Derive.make_lookup cmap] }

note_calls :: Derive.NoteCallMap
note_calls = Map.unions [Block.note_calls, Echo.note_calls, Note.note_calls,
    NoteTransformer.note_calls, Ornament.note_calls, Reverse.note_calls,
    Rambat.note_calls, Sekar.note_calls, String.note_calls, Trill.note_calls]

control_calls :: Derive.ControlCallMap
control_calls = Map.unions [Control.control_calls, Trill.control_calls]

pitch_calls :: Derive.PitchCallMap
pitch_calls = Map.unions [Pitch.pitch_calls, Trill.pitch_calls]

val_calls :: Derive.ValCallMap
val_calls = Map.unions []
