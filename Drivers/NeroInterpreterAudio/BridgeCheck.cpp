#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <chrono>
#include <vector>
#include <stdexcept>
#include <string>
#include <sys/file.h>
#include <unistd.h>

static void check(OSStatus status,const char* operation){if(status)throw std::runtime_error(std::string(operation)+": "+std::to_string(status));}
static AudioDeviceID find(CFStringRef uid){AudioDeviceID device=0;UInt32 size=sizeof(device);AudioObjectPropertyAddress a{kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,0};check(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(uid),&uid,&size,&device),"find device");return device;}
static void lease(AudioDeviceID device,bool enable){CFStringRef value=enable?CFSTR("renew-v1"):CFSTR("stop-v1");AudioObjectPropertyAddress a{'nrle',kAudioObjectPropertyScopeGlobal,0};check(AudioObjectSetPropertyData(device,&a,0,nullptr,sizeof(value),&value),"route lease");}
struct Probe {
 AudioDeviceID device=0;AudioDeviceIOProcID proc=nullptr;float level=0;bool started=false;
 std::atomic<int> phase{2};std::atomic<uint64_t> samples{0},bad{0};
 static OSStatus io(AudioObjectID,const AudioTimeStamp*,const AudioBufferList* input,const AudioTimeStamp*,AudioBufferList* output,const AudioTimeStamp*,void* raw){
  auto& p=*static_cast<Probe*>(raw);
  if(output)for(UInt32 b=0;b<output->mNumberBuffers;b++){auto& buf=output->mBuffers[b];auto f=static_cast<float*>(buf.mData);if(f)for(UInt32 i=0;i<buf.mDataByteSize/4;i++)f[i]=p.level;}
  int mode=p.phase.load();
  if(mode!=2 && input)for(UInt32 b=0;b<input->mNumberBuffers;b++){const auto& buf=input->mBuffers[b];auto f=static_cast<const float*>(buf.mData);if(!f)continue;uint64_t errors=0;for(UInt32 i=0;i<buf.mDataByteSize/4;i++)if(!std::isfinite(f[i])||std::abs(f[i]-(mode==1?p.level:0.f))>.001f)errors++;p.bad.fetch_add(errors);p.samples.fetch_add(buf.mDataByteSize/4);}
  return noErr;
 }
 void start(){AudioObjectPropertyAddress a{kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,0};Float64 rate=0;UInt32 size=sizeof(rate);check(AudioObjectGetPropertyData(device,&a,0,nullptr,&size,&rate),"sample rate");if(rate!=48000)throw std::runtime_error("Expected 48 kHz");
  check(AudioDeviceCreateIOProcID(device,io,this,&proc),"create virtual IO");check(AudioDeviceStart(device,proc),"start virtual IO");started=true;
 }
 void reset(int mode){phase=2;samples=0;bad=0;phase=mode;}
 ~Probe(){if(device){try{lease(device,false);}catch(...){}}if(started)AudioDeviceStop(device,proc);if(proc)AudioDeviceDestroyIOProcID(device,proc);}
};
static void wait(int ms){std::this_thread::sleep_for(std::chrono::milliseconds(ms));}
int main(int argc,char**argv){try{
 const bool test=argc==2&&std::string(argv[1])=="--self-test";
 if(argc!=2 || (!test&&std::string(argv[1])!="--list"))throw std::runtime_error("Use --list or --self-test (virtual routes only)");
 auto speaker=find(CFSTR("cafe.nero.interpreter.speaker.v1")),mic=find(CFSTR("cafe.nero.interpreter.microphone.v1"));
 if(!test){printf("{\"installed\":%s,\"speakerID\":%u,\"microphoneID\":%u}\n",speaker&&mic?"true":"false",speaker,mic);return 0;}
 if(!speaker||!mic)throw std::runtime_error("Nero audio driver is not loaded; install the package then restart the Mac");
 for(auto device:{speaker,mic}){AudioObjectPropertyAddress address{kAudioDevicePropertyDeviceIsRunningSomewhere,kAudioObjectPropertyScopeGlobal,0};UInt32 running=0,size=sizeof(running);check(AudioObjectGetPropertyData(device,&address,0,nullptr,&size,&running),"device activity");if(running)throw std::runtime_error("Close apps using Nero virtual audio before the isolated test");}
 Probe a,b;a.device=speaker;a.level=.125f;b.device=mic;b.level=-.25f;
 lease(speaker,false);lease(mic,false);a.start();b.start();
 auto verify=[&](const char*name,int expected,bool refresh,int steps){a.reset(expected);b.reset(expected);for(int i=0;i<steps;i++){if(refresh){lease(speaker,true);lease(mic,true);}wait(100);}a.phase=2;b.phase=2;
  printf("%s: speaker samples=%llu wrong=%llu; microphone samples=%llu wrong=%llu\n",name,(unsigned long long)a.samples.load(),(unsigned long long)a.bad.load(),(unsigned long long)b.samples.load(),(unsigned long long)b.bad.load());
  if(a.samples<4800||b.samples<4800||a.bad||b.bad)throw std::runtime_error(std::string("Audio assertion failed: ")+name);
 };
 wait(100);verify("default silence",0,false,2);
 for(int i=0;i<3;i++){lease(speaker,true);lease(mic,true);wait(100);}verify("isolated exact transport",1,true,5);
 lease(speaker,false);lease(mic,false);wait(100);verify("Stop silence",0,false,2);
 lease(speaker,true);lease(mic,true);wait(700);verify("expired heartbeat silence",0,false,2);
 for(int i=0;i<3;i++){lease(speaker,true);lease(mic,true);wait(100);}verify("restart transport",1,true,3);
 puts("PASS: both HAL routes, isolation, Stop, missing heartbeat and restart. No physical devices used.");return 0;
 }catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 1;}}
