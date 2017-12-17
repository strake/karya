-- Copyright 2017 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- automatically generated by extract_korvais
-- | Collect korvais into one database.
-- This is automatically generated, but checked in for convenience.
-- Don't edit it directly.  Any modifications to the the source
-- directory should cause it to be regenerated.
module Derive.Solkattu.All where
import qualified Derive.Solkattu.Korvai as Korvai
import Derive.Solkattu.Metadata
import qualified Derive.Solkattu.Score.Mridangam2013
import qualified Derive.Solkattu.Score.Mridangam2017
import qualified Derive.Solkattu.Score.MridangamSarva
import qualified Derive.Solkattu.Score.Solkattu2013
import qualified Derive.Solkattu.Score.Solkattu2014
import qualified Derive.Solkattu.Score.Solkattu2016
import qualified Derive.Solkattu.Score.Solkattu2017
import qualified Derive.Solkattu.Score.SolkattuMohra


korvais :: [Korvai.Korvai]
korvais =
    [ set_location ("Derive.Solkattu.Score.Mridangam2013",15,"dinnagina_sequence") Derive.Solkattu.Score.Mridangam2013.dinnagina_sequence
    , set_location ("Derive.Solkattu.Score.Mridangam2013",88,"t_16_11_14") Derive.Solkattu.Score.Mridangam2013.t_16_11_14
    , set_location ("Derive.Solkattu.Score.Mridangam2013",94,"t_17_02_13") Derive.Solkattu.Score.Mridangam2013.t_17_02_13
    , set_location ("Derive.Solkattu.Score.Mridangam2013",107,"din_nadin") Derive.Solkattu.Score.Mridangam2013.din_nadin
    , set_location ("Derive.Solkattu.Score.Mridangam2013",114,"nadin_ka") Derive.Solkattu.Score.Mridangam2013.nadin_ka
    , set_location ("Derive.Solkattu.Score.Mridangam2013",119,"nadindin") Derive.Solkattu.Score.Mridangam2013.nadindin
    , set_location ("Derive.Solkattu.Score.Mridangam2013",136,"nadindin_negative") Derive.Solkattu.Score.Mridangam2013.nadindin_negative
    , set_location ("Derive.Solkattu.Score.Mridangam2013",149,"namita_dimita") Derive.Solkattu.Score.Mridangam2013.namita_dimita
    , set_location ("Derive.Solkattu.Score.Mridangam2013",166,"janahan_exercise") Derive.Solkattu.Score.Mridangam2013.janahan_exercise
    , set_location ("Derive.Solkattu.Score.Mridangam2013",170,"nakanadin") Derive.Solkattu.Score.Mridangam2013.nakanadin
    , set_location ("Derive.Solkattu.Score.Mridangam2013",176,"p16_12_06_sriram2") Derive.Solkattu.Score.Mridangam2013.p16_12_06_sriram2
    , set_location ("Derive.Solkattu.Score.Mridangam2013",184,"p16_12_06_janahan1") Derive.Solkattu.Score.Mridangam2013.p16_12_06_janahan1
    , set_location ("Derive.Solkattu.Score.Mridangam2013",191,"p16_12_06_janahan2") Derive.Solkattu.Score.Mridangam2013.p16_12_06_janahan2
    , set_location ("Derive.Solkattu.Score.Mridangam2013",201,"farans") Derive.Solkattu.Score.Mridangam2013.farans
    , set_location ("Derive.Solkattu.Score.Mridangam2013",247,"eddupu6") Derive.Solkattu.Score.Mridangam2013.eddupu6
    , set_location ("Derive.Solkattu.Score.Mridangam2013",258,"eddupu10") Derive.Solkattu.Score.Mridangam2013.eddupu10
    , set_location ("Derive.Solkattu.Score.Mridangam2017",11,"c_17_07_10") Derive.Solkattu.Score.Mridangam2017.c_17_07_10
    , set_location ("Derive.Solkattu.Score.Mridangam2017",15,"e_1") Derive.Solkattu.Score.Mridangam2017.e_1
    , set_location ("Derive.Solkattu.Score.Mridangam2017",24,"e_2") Derive.Solkattu.Score.Mridangam2017.e_2
    , set_location ("Derive.Solkattu.Score.MridangamSarva",18,"kir1") Derive.Solkattu.Score.MridangamSarva.kir1
    , set_location ("Derive.Solkattu.Score.MridangamSarva",23,"kir2") Derive.Solkattu.Score.MridangamSarva.kir2
    , set_location ("Derive.Solkattu.Score.MridangamSarva",43,"kir3") Derive.Solkattu.Score.MridangamSarva.kir3
    , set_location ("Derive.Solkattu.Score.MridangamSarva",49,"kir4") Derive.Solkattu.Score.MridangamSarva.kir4
    , set_location ("Derive.Solkattu.Score.MridangamSarva",54,"kir5") Derive.Solkattu.Score.MridangamSarva.kir5
    , set_location ("Derive.Solkattu.Score.MridangamSarva",63,"mel1") Derive.Solkattu.Score.MridangamSarva.mel1
    , set_location ("Derive.Solkattu.Score.MridangamSarva",68,"mel2") Derive.Solkattu.Score.MridangamSarva.mel2
    , set_location ("Derive.Solkattu.Score.MridangamSarva",75,"dinna_kitataka") Derive.Solkattu.Score.MridangamSarva.dinna_kitataka
    , set_location ("Derive.Solkattu.Score.MridangamSarva",88,"farans") Derive.Solkattu.Score.MridangamSarva.farans
    , set_location ("Derive.Solkattu.Score.MridangamSarva",101,"kir6") Derive.Solkattu.Score.MridangamSarva.kir6
    , set_location ("Derive.Solkattu.Score.MridangamSarva",123,"kir_misra_1") Derive.Solkattu.Score.MridangamSarva.kir_misra_1
    , set_location ("Derive.Solkattu.Score.MridangamSarva",129,"kir_misra_2") Derive.Solkattu.Score.MridangamSarva.kir_misra_2
    , set_location ("Derive.Solkattu.Score.MridangamSarva",134,"c_17_10_23a") Derive.Solkattu.Score.MridangamSarva.c_17_10_23a
    , set_location ("Derive.Solkattu.Score.MridangamSarva",140,"c_17_10_23b") Derive.Solkattu.Score.MridangamSarva.c_17_10_23b
    , set_location ("Derive.Solkattu.Score.Solkattu2013",21,"c_13_07_23") Derive.Solkattu.Score.Solkattu2013.c_13_07_23
    , set_location ("Derive.Solkattu.Score.Solkattu2013",28,"c_13_08_14") Derive.Solkattu.Score.Solkattu2013.c_13_08_14
    , set_location ("Derive.Solkattu.Score.Solkattu2013",68,"c_yt1") Derive.Solkattu.Score.Solkattu2013.c_yt1
    , set_location ("Derive.Solkattu.Score.Solkattu2013",80,"c_13_10_29") Derive.Solkattu.Score.Solkattu2013.c_13_10_29
    , set_location ("Derive.Solkattu.Score.Solkattu2013",94,"c_13_11_05") Derive.Solkattu.Score.Solkattu2013.c_13_11_05
    , set_location ("Derive.Solkattu.Score.Solkattu2013",102,"c_13_11_12") Derive.Solkattu.Score.Solkattu2013.c_13_11_12
    , set_location ("Derive.Solkattu.Score.Solkattu2013",119,"c_13_12_11") Derive.Solkattu.Score.Solkattu2013.c_13_12_11
    , set_location ("Derive.Solkattu.Score.Solkattu2013",157,"k1_1") Derive.Solkattu.Score.Solkattu2013.k1_1
    , set_location ("Derive.Solkattu.Score.Solkattu2013",174,"k1_2") Derive.Solkattu.Score.Solkattu2013.k1_2
    , set_location ("Derive.Solkattu.Score.Solkattu2013",187,"k1_3") Derive.Solkattu.Score.Solkattu2013.k1_3
    , set_location ("Derive.Solkattu.Score.Solkattu2013",221,"k3s") Derive.Solkattu.Score.Solkattu2013.k3s
    , set_location ("Derive.Solkattu.Score.Solkattu2013",266,"t1s") Derive.Solkattu.Score.Solkattu2013.t1s
    , set_location ("Derive.Solkattu.Score.Solkattu2013",288,"t2s") Derive.Solkattu.Score.Solkattu2013.t2s
    , set_location ("Derive.Solkattu.Score.Solkattu2013",321,"t3s") Derive.Solkattu.Score.Solkattu2013.t3s
    , set_location ("Derive.Solkattu.Score.Solkattu2013",358,"t4s2") Derive.Solkattu.Score.Solkattu2013.t4s2
    , set_location ("Derive.Solkattu.Score.Solkattu2013",383,"t4s3") Derive.Solkattu.Score.Solkattu2013.t4s3
    , set_location ("Derive.Solkattu.Score.Solkattu2013",406,"t5s") Derive.Solkattu.Score.Solkattu2013.t5s
    , set_location ("Derive.Solkattu.Score.Solkattu2013",462,"koraippu_misra") Derive.Solkattu.Score.Solkattu2013.koraippu_misra
    , set_location ("Derive.Solkattu.Score.Solkattu2013",501,"tir_18") Derive.Solkattu.Score.Solkattu2013.tir_18
    , set_location ("Derive.Solkattu.Score.Solkattu2014",17,"c_14_01_01") Derive.Solkattu.Score.Solkattu2014.c_14_01_01
    , set_location ("Derive.Solkattu.Score.Solkattu2014",42,"c_14_01_14") Derive.Solkattu.Score.Solkattu2014.c_14_01_14
    , set_location ("Derive.Solkattu.Score.Solkattu2014",78,"c_14_02_05") Derive.Solkattu.Score.Solkattu2014.c_14_02_05
    , set_location ("Derive.Solkattu.Score.Solkattu2014",118,"c_14_02_20") Derive.Solkattu.Score.Solkattu2014.c_14_02_20
    , set_location ("Derive.Solkattu.Score.Solkattu2014",146,"c_14_02_27") Derive.Solkattu.Score.Solkattu2014.c_14_02_27
    , set_location ("Derive.Solkattu.Score.Solkattu2014",181,"c_14_03_13") Derive.Solkattu.Score.Solkattu2014.c_14_03_13
    , set_location ("Derive.Solkattu.Score.Solkattu2014",203,"c_14_03_26") Derive.Solkattu.Score.Solkattu2014.c_14_03_26
    , set_location ("Derive.Solkattu.Score.Solkattu2014",230,"c_14_04_21") Derive.Solkattu.Score.Solkattu2014.c_14_04_21
    , set_location ("Derive.Solkattu.Score.Solkattu2014",248,"c_14_04_29") Derive.Solkattu.Score.Solkattu2014.c_14_04_29
    , set_location ("Derive.Solkattu.Score.Solkattu2014",284,"c_14_06_06") Derive.Solkattu.Score.Solkattu2014.c_14_06_06
    , set_location ("Derive.Solkattu.Score.Solkattu2016",13,"c_16_09_28") Derive.Solkattu.Score.Solkattu2016.c_16_09_28
    , set_location ("Derive.Solkattu.Score.Solkattu2016",39,"c_16_12_06_sriram1") Derive.Solkattu.Score.Solkattu2016.c_16_12_06_sriram1
    , set_location ("Derive.Solkattu.Score.Solkattu2017",20,"koraippu_janahan") Derive.Solkattu.Score.Solkattu2017.koraippu_janahan
    , set_location ("Derive.Solkattu.Score.Solkattu2017",79,"e_spacing") Derive.Solkattu.Score.Solkattu2017.e_spacing
    , set_location ("Derive.Solkattu.Score.Solkattu2017",94,"c_17_02_06") Derive.Solkattu.Score.Solkattu2017.c_17_02_06
    , set_location ("Derive.Solkattu.Score.Solkattu2017",104,"c_17_03_20") Derive.Solkattu.Score.Solkattu2017.c_17_03_20
    , set_location ("Derive.Solkattu.Score.Solkattu2017",127,"c_17_09_25") Derive.Solkattu.Score.Solkattu2017.c_17_09_25
    , set_location ("Derive.Solkattu.Score.Solkattu2017",152,"c_17_04_04") Derive.Solkattu.Score.Solkattu2017.c_17_04_04
    , set_location ("Derive.Solkattu.Score.Solkattu2017",178,"c_17_04_23") Derive.Solkattu.Score.Solkattu2017.c_17_04_23
    , set_location ("Derive.Solkattu.Score.Solkattu2017",203,"c_17_05_10") Derive.Solkattu.Score.Solkattu2017.c_17_05_10
    , set_location ("Derive.Solkattu.Score.Solkattu2017",251,"c_17_05_11") Derive.Solkattu.Score.Solkattu2017.c_17_05_11
    , set_location ("Derive.Solkattu.Score.Solkattu2017",279,"c_17_05_19") Derive.Solkattu.Score.Solkattu2017.c_17_05_19
    , set_location ("Derive.Solkattu.Score.Solkattu2017",285,"c_17_05_19_janahan") Derive.Solkattu.Score.Solkattu2017.c_17_05_19_janahan
    , set_location ("Derive.Solkattu.Score.Solkattu2017",308,"c_17_06_02_janahan") Derive.Solkattu.Score.Solkattu2017.c_17_06_02_janahan
    , set_location ("Derive.Solkattu.Score.Solkattu2017",321,"c_17_06_15") Derive.Solkattu.Score.Solkattu2017.c_17_06_15
    , set_location ("Derive.Solkattu.Score.Solkattu2017",336,"c_17_06_19") Derive.Solkattu.Score.Solkattu2017.c_17_06_19
    , set_location ("Derive.Solkattu.Score.Solkattu2017",362,"c_17_06_19_koraippu") Derive.Solkattu.Score.Solkattu2017.c_17_06_19_koraippu
    , set_location ("Derive.Solkattu.Score.Solkattu2017",387,"c_17_07_13") Derive.Solkattu.Score.Solkattu2017.c_17_07_13
    , set_location ("Derive.Solkattu.Score.Solkattu2017",481,"c_17_07_19") Derive.Solkattu.Score.Solkattu2017.c_17_07_19
    , set_location ("Derive.Solkattu.Score.Solkattu2017",494,"c_17_08_21") Derive.Solkattu.Score.Solkattu2017.c_17_08_21
    , set_location ("Derive.Solkattu.Score.Solkattu2017",516,"c_17_08_29") Derive.Solkattu.Score.Solkattu2017.c_17_08_29
    , set_location ("Derive.Solkattu.Score.Solkattu2017",593,"c_17_10_23") Derive.Solkattu.Score.Solkattu2017.c_17_10_23
    , set_location ("Derive.Solkattu.Score.Solkattu2017",653,"c_17_12_11") Derive.Solkattu.Score.Solkattu2017.c_17_12_11
    , set_location ("Derive.Solkattu.Score.SolkattuMohra",33,"c_mohra") Derive.Solkattu.Score.SolkattuMohra.c_mohra
    , set_location ("Derive.Solkattu.Score.SolkattuMohra",50,"c_mohra2") Derive.Solkattu.Score.SolkattuMohra.c_mohra2
    , set_location ("Derive.Solkattu.Score.SolkattuMohra",68,"c_mohra_youtube") Derive.Solkattu.Score.SolkattuMohra.c_mohra_youtube
    ]
