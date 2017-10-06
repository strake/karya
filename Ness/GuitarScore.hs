{-# LANGUAGE RecordWildCards #-}
module Ness.GuitarScore where
import Ness.Guitar
import qualified Ness.Util as Util


Util.Interactive {..} = Util.interactive "guitar" renderAll
    instrument0 score0

strings =
    [ String 0.68 2e11 12.1 0.0002 7850 15 5 [Output 0.9 0.3]
    , String 0.68 2e11 12.3 0.00015 7850 15 5 [Output 0.9 0.4]
    , String 0.68 2e11 21.9 0.00015 7850 15 5 [Output 0.9 (-0.4)]
    , String 0.68 2e11 39.2 0.00015 7850 15 7 [Output 0.9 0.4]
    , String 0.68 2e11 27.6 0.0001 7850 15 5 [Output 0.9 0.1]
    , String 0.68 2e11 49.2 0.0001 7850 15 8 [Output 0.9 (-0.4)]
    ]
frets = map (\p -> Fret { fLocation = p, fHeight = -0.01 })
    [ 0.056125687318306
    , 0.109101281859661
    , 0.159103584746285
    , 0.206299474015900
    , 0.250846461561659
    , 0.292893218813453
    , 0.332580072914983
    , 0.370039475052563
    , 0.405396442498639
    , 0.438768975845313
    , 0.470268452820352
    , 0.500000000000000
    , 0.528062843659153
    , 0.554550640929830
    , 0.579551792373143
    , 0.603149737007950
    , 0.625423230780830
    , 0.646446609406726
    , 0.666290036457491
    , 0.685019737526282
    ]

instrument0 = Instrument
    { iStrings = strings
    , iFrets = []
    , iBarrier = Barrier 1e10 1.3 10 (Solver 20 1e-12)
    , iBackboard = Backboard (-0.002) (-0.001) (-0.0002)
    , iFingerParams = FingerParams 0.005 1e7 3.3 100
    , iNormalizeOutputs = True
    , iSolver = Solver 20 0
    , iConnections = []
    }

score0 = Score
    { sHighpass = True
    , sNotes = notes0
    , sFingers = fingers0
    }

-- there's rattle from amp .75 to .4
-- duration makes a more rounded sound around 0.007 to .015, but becomes no
-- sound around .03

[str1, str2, str3, str4, str5, str6] = strings
notes0 = map make
    [ (str1, 0.010000000000000, 0.001299965854261, 0.753352341821251)

    -- , (str1, 1, 0.001299965854261, 0.7)
    -- , (str1, 2, 0.001299965854261, 0.6)
    -- , (str1, 3, 0.001299965854261, 0.5)
    -- , (str1, 3, 0.001299965854261, 0.4) -- no strike
    -- , (str1, 4, 0.001299965854261, 0.3)
    -- , (str1, 5, 0.001299965854261, 0.2)
    -- , (str1, 6, 0.001299965854261, 0.1)
    -- , (str1, 7, 0.001299965854261, 0.05)

    -- , (str1, 1, 0.0013, 0.4)
    -- , (str1, 2, 0.0019, 0.4)
    -- , (str1, 3, 0.0024, 0.4)
    -- , (str1, 3, 0.0035, 0.4)
    -- , (str1, 4, 0.007, 0.4) -- softer
    -- , (str1, 5, 0.015, 0.4) -- just a flick
    -- , (str1, 6, 0.030, 0.4) -- no sound
    -- , (str1, 7, 0.101, 0.4)

    -- , (str2, 0.022500000000000, 0.001734179906576, 0.570954585011654)
    -- , (str3, 0.035000000000000, 0.001104209253757, 1.125803331171040)
    -- , (str4, 0.047500000000000, 0.001792575487554, 0.524681470128999)
    -- , (str5, 0.060000000000000, 0.001782728942752, 0.562042492509529)
    -- , (str6, 0.072500000000000, 0.001532397693219, 0.629611982278315)
    -- , (str6, 0.260000000000000, 0.001450614072287, 1.141631167720519)
    -- , (str5, 0.272500000000000, 0.001672335843923, 1.286386643614576)
    -- , (str4, 0.285000000000000, 0.001856110833478, 0.789150493176199)
    -- , (str3, 0.297500000000000, 0.001498445424255, 0.997868010687049)
    -- , (str2, 0.310000000000000, 0.001048784504036, 1.318434615976952)
    -- , (str1, 0.322500000000000, 0.001313832359873, 1.095128292529225)
    ]
    where
    make (str, start, dur, amp) = Note
        { nStrike = Strike
        , nString = str
        , nStart = start
        , nDuration = dur
        , nLocation = 0.8
        , nAmplitude = amp
        }

fingers0 =
    -- str initial bps
    [
      Finger str1 (0.01, 0)
        [ (1, 0.038, 0), (3, 0.038, 0.01)
        ]

    --   Finger str1 (0.01, 0)
    --     [ (0, 0.038, 0), (0.18, 0.148, 0), (0.31, 0.093, 1.0)
    --     , (0.78, 0.173, 1.0), (1.0, 0.283, 1.0)
    --     ]
    --
    -- , Finger str2 (0.01, 0)
    --     [ (0, 0.236, 0), (0.18, 0.153, 0), (0.31, 0.168, 1.0)
    --     , (0.78, 0.205, 1.0), (1.0, 0.027, 1.0)
    --     ]
    -- , Finger str3 (0.01, 0)
    --     [ (0, 0.157, 0), (0.18, 0.195, 0), (0.31, 0.115, 1.0)
    --     , (0.78, 0.194, 1.0), (1.0, 0.228, 1.0)
    --     ]
    -- , Finger str4 (0.01, 0)
    --     [ (0, 0.250, 0), (0.18, 0.081, 0), (0.31, 0.120, 1.0)
    --     , (0.78, 0.166, 1.0), (1.0, 0.133, 1.0)
    --     ]
    -- , Finger str5 (0.01, 0)
    --     [ (0, 0.156, 0), (0.18, 0.272, 0), (0.31, 0.114, 1.0)
    --     , (0.78, 0.265, 1.0), (1.0, 0.076, 1.0)
    --     ]
    -- , Finger str6 (0.01, 0)
    --     [ (0, 0.064, 0), (0.18, 0.001, 0), (0.31, 0.264, 1.0)
    --     , (0.78, 0.070, 1.0), (1.0, 0.073, 1.0)
    --     ]
    ]
