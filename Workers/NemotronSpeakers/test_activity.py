import unittest
import numpy as np
from activity import SpeakerActivity


def run(values, sizes, **kw):
    state=SpeakerActivity(**kw); spans=[]; cursor=0
    for size in sizes:
        part=values[cursor:cursor+size]; cursor+=size
        found,through=state.feed(part); spans.extend(found)
        assert len(state.pending)<=state.pad
        assert through <= cursor*state.stride
    found,through=state.feed(values[cursor:],final=True); spans.extend(found)
    # Compare framewise coverage, not arbitrary per-message span fragmentation.
    coverage=np.zeros(values.shape,dtype=bool)
    for s in spans:
        coverage[round(s['start']/state.stride):round(s['end']/state.stride),s['speaker']]=True
    return coverage,through,state


class ActivityTests(unittest.TestCase):
    def test_packet_boundaries_and_final_tail_match(self):
        p=np.zeros((503,8),dtype=np.float32)
        p[20:24,0]=.6; p[24:97,0]=.3; p[90:140,1]=.7
        p[490:,2]=.8
        expected,through,_=run(p,[],offset=.25,pad_frames=8)
        for sizes in [[1]*503,[17]*29,[180,1,14,200],[100,100,100,100,100]]:
            actual,end,_=run(p,sizes,offset=.25,pad_frames=8); np.testing.assert_array_equal(expected,actual)
            self.assertAlmostEqual(end,through)
        self.assertEqual(through,5.03)
        self.assertTrue(expected[12:105,0].all())
        self.assertTrue(expected[490:,2].all())
    def test_production_policy_exact_edges_and_partition_independence(self):
        p=np.zeros((503,8),dtype=np.float32)
        p[20:24,0]=.6; p[24:97,0]=.3; p[90:140,1]=.7; p[490:,2]=.8
        expected,through,_=run(p,[])
        self.assertTrue(expected[16:28,0].all())
        self.assertFalse(expected[28:86,0].any())  # weak activity is not extended
        for sizes in [[1]*503,[17]*29,[180,1,14,200],[100]*5]:
            actual,end,_=run(p,sizes)
            np.testing.assert_array_equal(expected,actual)
            self.assertEqual(end,through)
        self.assertTrue(expected[486:,2].all())
    def test_unseeded_noise_cannot_start_a_speaker(self):
        p=np.full((1000,8),.3,dtype=np.float32)
        coverage,_,state=run(p,[1]*1000)
        self.assertFalse(coverage.any()); self.assertEqual(state.pending,[])
    def test_overlap_is_preserved_and_quiet_tail_clipped(self):
        p=np.zeros((20,8),dtype=np.float32);p[0:5,:2]=.8
        coverage,_,_=run(p,[4,5,3],offset=.25,pad_frames=8)
        self.assertTrue(coverage[:13,:2].all());self.assertFalse(coverage[13:].any())
    def test_empty_flush_and_invalid_or_late_data(self):
        state=SpeakerActivity(); self.assertEqual(state.feed(np.zeros((0,8)),final=True),([],0))
        with self.assertRaises(ValueError):state.feed(np.zeros((1,8)))
        for p in [np.array([[float('nan')]*8]),np.ones((2,7)),np.ones((2,8))*1.1]:
            with self.assertRaises(ValueError):SpeakerActivity().feed(p)
    def test_no_padding_matches_causal_hysteresis(self):
        p=np.zeros((5,1));p[:,0]=[.3,.6,.3,.2,.4]
        coverage,_,_=run(p,[1,1],speakers=1,pad_frames=0,offset=.25)
        self.assertEqual(coverage[:,0].tolist(),[False,True,True,False,False])

if __name__=='__main__':unittest.main()
