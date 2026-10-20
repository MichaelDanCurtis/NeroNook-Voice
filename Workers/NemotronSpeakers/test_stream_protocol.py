import io,json,struct,unittest
from stream_protocol import packets

def frame(header,data=b''):
 raw=json.dumps(header).encode();return struct.pack('<I',len(raw))+raw+data
class ProtocolTests(unittest.TestCase):
 def test_sources_clock_and_finalization(self):
  raw=frame(dict(track='mic',start=2,length=4),b'\0'*4)+frame(dict(track='system',start=2.25,length=4),b'\0'*4)+b'\0'*4
  self.assertEqual([(a,b) for a,b,c in packets(io.BytesIO(raw))],[('mic',2),('system',2.25)])
 def test_rejects_unbounded_and_invalid_input(self):
  for h in [dict(track='other',start=0,length=4),dict(track='mic',start=float('nan'),length=4),dict(track='mic',start=0,length=65540),dict(track='mic',start=True,length=4),dict(track='mic',start=14430,length=4)]:
   with self.assertRaises(ValueError):list(packets(io.BytesIO(frame(h))))
 def test_truncated_input_is_not_clean_finalization(self):
  with self.assertRaises(ValueError):list(packets(io.BytesIO(frame(dict(track='mic',start=0,length=8),b'\0'*4))))
  with self.assertRaises(ValueError):list(packets(io.BytesIO(struct.pack('<I',2000))))
if __name__=='__main__':unittest.main()
