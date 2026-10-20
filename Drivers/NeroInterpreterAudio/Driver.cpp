// Nero-owned route implementation using the MIT-licensed libASPL interface.
#include <aspl/Driver.hpp>
#include <mach/mach_time.h>
#include "TimedRing.hpp"

constexpr AudioObjectPropertySelector LeaseProperty='nrle';
class Route:public aspl::IORequestHandler,public aspl::ControlRequestHandler {
public:
 TimedRing ring;
 uint64_t ttl;
 Route(){mach_timebase_info_data_t info;mach_timebase_info(&info);ttl=500000000ULL*info.denom/info.numer;}
 void OnStopIO() override {ring.stop();}
 void OnReadClientInput(const std::shared_ptr<aspl::Client>&,const std::shared_ptr<aspl::Stream>&,Float64,Float64 timestamp,void* bytes,UInt32 count) override {
  std::memset(bytes,0,count);
  if(!std::isfinite(timestamp)||timestamp<0||timestamp>double(INT64_MAX)||count%8)return;
  ring.read(uint64_t(timestamp),static_cast<float*>(bytes),count/8,mach_absolute_time());
 }
 void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,Float64,Float64 timestamp,const void* bytes,UInt32 count) override {
  if(!std::isfinite(timestamp)||timestamp<0||timestamp>double(INT64_MAX)||count%8)return;
  ring.write(uint64_t(timestamp),static_cast<const float*>(bytes),count/8,mach_absolute_time());
 }
};
class RouteDevice:public aspl::Device {
public:
 RouteDevice(std::shared_ptr<aspl::Context> context,const aspl::DeviceParameters& params):aspl::Device(context,params),route(std::make_shared<Route>()) {
  SetIOHandler(route);SetControlHandler(route);
  RegisterCustomProperty(LeaseProperty,*this,&RouteDevice::GetLease,&RouteDevice::SetLease);
 }
 CFStringRef GetLease() const {return static_cast<CFStringRef>(CFRetain(route->ring.active(mach_absolute_time())?CFSTR("active"):CFSTR("silent")));}
 void SetLease(CFStringRef value) {
  if(value && CFGetTypeID(value)==CFStringGetTypeID() && CFEqual(value,CFSTR("renew-v1")))route->ring.renew(mach_absolute_time(),route->ttl);
  else route->ring.stop();
 }
private:std::shared_ptr<Route> route;
};
std::shared_ptr<aspl::Driver> CreateDriver() {
 auto context=std::make_shared<aspl::Context>();auto plugin=std::make_shared<aspl::Plugin>(context);
 for(int index=0;index<2;index++) {
  aspl::DeviceParameters p;p.Name=index?"Nero Interpreter Microphone":"Nero Interpreter Speaker";
  p.Manufacturer="Nero Voice";p.DeviceUID=index?"cafe.nero.interpreter.microphone.v1":"cafe.nero.interpreter.speaker.v1";
  p.ModelUID="cafe.nero.interpreter.audio.v1";p.SampleRate=48000;p.ChannelCount=2;
  p.CanBeDefault=false;p.CanBeDefaultForSystemSounds=false;p.EnableMixing=true;
  p.ZeroTimeStampPeriod=512;p.Latency=0;
  auto device=std::make_shared<RouteDevice>(context,p);
  for(auto direction:{aspl::Direction::Input,aspl::Direction::Output}) {
   aspl::StreamParameters stream;stream.Direction=direction;
   stream.Format={48000,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,8,1,8,2,32,0};
   stream.Latency=direction==aspl::Direction::Input?TimedRing::Delay:0;
   device->AddStreamAsync(stream);
  }
  plugin->AddDevice(device);
 }
 return std::make_shared<aspl::Driver>(context,plugin);
}
extern "C" void* NeroInterpreterEntryPoint(CFAllocatorRef,CFUUIDRef type) {
 if(!CFEqual(type,kAudioServerPlugInTypeUUID))return nullptr;
 static auto driver=CreateDriver();return driver->GetReference();
}
