#pragma once
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

// One mixed HAL writer, concurrent readers. No allocation, lock or IO in callbacks.
// Timestamp + epoch prevents buffer wrap, Stop/restart and stale audio replay.
class TimedRing {
public:
 static constexpr uint32_t Capacity=32768, Delay=2048, Channels=2;
 static constexpr uint64_t Invalid=std::numeric_limits<uint64_t>::max();
 static_assert(std::atomic<uint64_t>::is_always_lock_free);
 static_assert(std::atomic<uint32_t>::is_always_lock_free);
 void renew(uint64_t now,uint64_t ttl) {
  if(now>=deadline.load()) epoch.fetch_add(1);
  deadline.store(now+ttl);
 }
 void stop() { deadline.store(0);epoch.fetch_add(1); }
 bool active(uint64_t now) const { return now<deadline.load(); }
 void write(uint64_t frame,const float* data,uint32_t frames,uint64_t now) {
  if(frames>Capacity || frame>Invalid-Capacity || !active(now)) return;
  const auto generation=epoch.load();
  for(uint32_t i=0;i<frames;i++) {
   auto& slot=slots[(frame+i)%Capacity];slot.stamp.store(Invalid);
   for(uint32_t c=0;c<Channels;c++) {
    float sample=data[i*Channels+c]; if(!std::isfinite(sample))sample=0;
    sample=std::fmax(-1.f,std::fmin(1.f,sample));
    uint32_t bits;std::memcpy(&bits,&sample,sizeof bits);slot.bits[c].store(bits);
   }
   slot.generation.store(generation);slot.stamp.store(frame+i);
  }
 }
 void read(uint64_t frame,float* data,uint32_t frames,uint64_t now) const {
  std::memset(data,0,size_t(frames)*Channels*sizeof(float));
  if(frames>Capacity || frame>Invalid-Capacity || !active(now))return;
  const auto generation=epoch.load();
  for(uint32_t i=0;i<frames;i++) {
   if(frame+i<Delay)continue;
   const auto wanted=frame+i-Delay;const auto& slot=slots[wanted%Capacity];
   const auto first=slot.stamp.load();if(first!=wanted)continue;
   float values[Channels];for(uint32_t c=0;c<Channels;c++){auto bits=slot.bits[c].load();std::memcpy(&values[c],&bits,sizeof bits);}
   if(slot.generation.load()!=generation || slot.stamp.load()!=first)continue;
   for(uint32_t c=0;c<Channels;c++)data[i*Channels+c]=values[c];
  }
  if(epoch.load()!=generation || !active(now))std::memset(data,0,size_t(frames)*Channels*sizeof(float));
 }
private:
 struct Slot {std::atomic<uint64_t> stamp{Invalid},generation{0};std::array<std::atomic<uint32_t>,Channels> bits{};};
 std::array<Slot,Capacity> slots{};
 std::atomic<uint64_t> epoch{1},deadline{0};
};
