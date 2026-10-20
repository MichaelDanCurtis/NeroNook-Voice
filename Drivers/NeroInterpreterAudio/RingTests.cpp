#include "TimedRing.hpp"
#include <cassert>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>
int main(){
 auto a=std::make_unique<TimedRing>(),b=std::make_unique<TimedRing>();
 float src[8]={.1f,.2f,.3f,.4f,.5f,.6f,.7f,.8f},out[8];
 a->write(0,src,4,1);a->read(2048,out,4,1);assert(out[0]==0);
 a->renew(10,500);a->write(0,src,4,11);a->read(2048,out,4,12);assert(out[0]==.1f&&out[7]==.8f);
 b->renew(10,500);b->read(2048,out,4,12);assert(out[0]==0); // route isolation
 a->read(2048+TimedRing::Capacity,out,4,12);assert(out[0]==0); // no wrap replay
 a->read(2048,out,4,511);assert(out[0]==0); // crash/stall expiry
 a->renew(512,500);a->read(2048,out,4,513);assert(out[0]==0); // expiry invalidates history
 a->write(4,src,4,514);a->stop();a->renew(515,500);a->read(2052,out,4,516);assert(out[0]==0);
 a->write(UINT64_MAX-1,src,4,516);a->read(UINT64_MAX-1,out,4,516);assert(out[0]==0);
 src[0]=NAN;src[1]=INFINITY;src[2]=2;src[3]=-2;a->write(10,src,4,520);a->read(2058,out,4,521);assert(out[0]==0&&out[1]==0&&out[2]==1&&out[3]==-1);
 // Concurrent wraparound readers must never see torn frames; ASPL serializes the mixed writer.
 std::atomic<bool> done{false};a->renew(600,100000);
 std::thread writer([&]{float x[2]={.25f,.25f};for(uint64_t i=0;i<200000;i++)a->write(i,x,1,601);done=true;});
 std::thread reader([&]{float x[2];for(uint64_t i=0;!done;i++){a->read(2048+i%200000,x,1,601);assert(std::isfinite(x[0])&&std::abs(x[0])<=1);}});
 writer.join();reader.join();std::cout<<"PASS: silence, isolation, exact transport, expiry, restart, wrap, finite samples and concurrent access\n";
}
