#include <aspl/Driver.hpp>
#include <cassert>
#include <iostream>
#include <thread>
#include <chrono>
std::shared_ptr<aspl::Driver> CreateDriver();
int main(){
 auto driver=CreateDriver();auto plugin=driver->GetPlugin();assert(plugin->GetDeviceCount()==2);
 auto a=plugin->GetDeviceByIndex(0),b=plugin->GetDeviceByIndex(1);
 assert(a->GetDeviceUID()!=b->GetDeviceUID());
 AudioObjectPropertyAddress prop{'nrle',kAudioObjectPropertyScopeGlobal,0};
 auto set=[&](std::shared_ptr<aspl::Device> d,CFStringRef value){assert(d->SetPropertyData(d->GetID(),0,&prop,0,nullptr,sizeof(value),&value)==noErr);};
 float input[512],output[512];for(auto&x:input)x=.25f;
 for(auto d:{a,b}){
  assert(d->GetNominalSampleRate()==48000);assert(!d->GetCanBeDefaultDevice());assert(!d->GetCanBeDefaultSystemDevice());
  assert(d->GetStreamCount(aspl::Direction::Input)==1&&d->GetStreamCount(aspl::Direction::Output)==1);
  auto in=d->GetStreamByIndex(aspl::Direction::Input,0);assert(in->GetPhysicalFormat().mFormatFlags==kAudioFormatFlagsNativeFloatPacked);assert(in->GetLatency()==2048);
  assert(d->SetNominalSampleRateAsync(44100)!=noErr);
  assert(d->HasProperty(d->GetID(),0,&prop));
  d->GetIOHandler()->OnReadClientInput(nullptr,in,0,2048,output,sizeof output);for(float x:output)assert(x==0);
 }
 auto out=a->GetStreamByIndex(aspl::Direction::Output,0),in=a->GetStreamByIndex(aspl::Direction::Input,0);
 set(a,CFSTR("renew-v1"));set(b,CFSTR("renew-v1"));
 a->GetIOHandler()->OnWriteMixedOutput(out,0,0,input,sizeof input);
 a->GetIOHandler()->OnReadClientInput(nullptr,in,0,2048,output,sizeof output);for(float x:output)assert(x==.25f);
 b->GetIOHandler()->OnReadClientInput(nullptr,b->GetStreamByIndex(aspl::Direction::Input,0),0,2048,output,sizeof output);for(float x:output)assert(x==0);
 set(a,CFSTR("stop-v1"));set(a,CFSTR("renew-v1"));a->GetIOHandler()->OnReadClientInput(nullptr,in,0,2048,output,sizeof output);for(float x:output)assert(x==0);
 a->GetIOHandler()->OnWriteMixedOutput(out,0,0,input,sizeof input);
 std::this_thread::sleep_for(std::chrono::milliseconds(550));a->GetIOHandler()->OnReadClientInput(nullptr,in,0,2048,output,sizeof output);for(float x:output)assert(x==0);
 set(a,CFSTR("invalid"));
 puts("PASS: actual driver object graph, fixed format, property control, route isolation, Stop generation and heartbeat timeout. In-process only; not HAL installation.");
}
