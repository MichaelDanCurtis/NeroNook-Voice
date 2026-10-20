import json,subprocess,sys,tempfile,time,unittest,wave
from pathlib import Path
from unittest.mock import patch
from check import execute,process_audio,validate_source,preview_lease

class BoundsTests(unittest.TestCase):
 def test_long_audio_rejected_before_conversion(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);source=root/'long.wav'
   with wave.open(str(source),'wb') as f:
    f.setparams((1,2,16000,0,'NONE','not compressed'));f.writeframes(b'\0\0'*16000*31)
   with self.assertRaisesRegex(ValueError,'30 seconds'):process_audio(source,'es',root/'result')
   self.assertFalse((root/'result/input.caf').exists())
   self.assertEqual(json.loads((root/'result/result.json').read_text())['status'],'failed')
 def test_invalid_direction_does_not_create_run(self):
  with tempfile.TemporaryDirectory() as d:
   out=Path(d)/'out'
   with self.assertRaises(ValueError):process_audio('/missing','xx',out)
   self.assertFalse(out.exists())
 def test_existing_run_never_overwritten(self):
  with tempfile.TemporaryDirectory() as d:
   marker=Path(d)/'result.json';marker.write_text('original')
   with self.assertRaises(FileExistsError):process_audio('/missing','es',d)
   self.assertEqual(marker.read_text(),'original')
 def test_timed_out_child_is_reaped(self):
  with tempfile.TemporaryDirectory() as d:
   pid=Path(d)/'pid';log=Path(d)/'log'
   code='import os,time;open('+repr(str(pid))+',"w").write(str(os.getpid()));time.sleep(20)'
   with self.assertRaises(subprocess.TimeoutExpired):execute([sys.executable,'-c',code],log,timeout=0.3)
   import os
   with self.assertRaises(ProcessLookupError):os.kill(int(pid.read_text()),0)
 def test_preview_lease_rejects_second_owner(self):
  with tempfile.TemporaryDirectory() as d,patch('check.ROOT',Path(d)):
   with preview_lease():
    with self.assertRaisesRegex(RuntimeError,'already running'):
     with preview_lease():pass
   with preview_lease():pass

if __name__=='__main__':unittest.main()
