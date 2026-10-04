#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

struct GBubble { long2 identity; float4 physical; float4 angular; };
struct GSegment { long2 identity; uint4 flags; float4 previous; float4 current; float4 velocity; float4 collision; };
struct GContact {
    ulong2 identity; long2 bubbles; long2 segmentAndAge;
    float4 geometry; float4 timing; float4 compression; float4 response;
};
struct GEvent { GContact contact; float4 timing; uint4 grouping; };
struct GParameters { uint4 counts; uint4 capacities; float4 physics; float4 events; uint4 limits; };
struct GControl { uint4 counts; uint4 required; uint4 flags; uint4 grouping; };

float gDot(float2 a, float2 b) { return a.x*b.x + a.y*b.y; }
float gLength(float2 a) { return sqrt(gDot(a,a)); }
float gCross(float2 a, float2 b) { return a.x*b.y-a.y*b.x; }
float2 gNormal(float2 a, float2 fallback) {
    float squared = gDot(a,a);
    return isfinite(squared) && squared > FLT_EPSILON ? a/sqrt(squared) : fallback;
}
float2 gClosest(float2 p, float2 a, float2 b) {
    float2 edge=b-a; float square=gDot(edge,edge);
    if (!isfinite(square) || square <= FLT_EPSILON) return a;
    return a+edge*min(1.0f,max(0.0f,gDot(p-a,edge)/square));
}
ulong gPairID(long a, long b) { return (ulong(uint(min(a,b)))<<32) | ulong(uint(max(a,b))); }
ulong gSegmentID(long a,long s) { return (1ul<<63) | (ulong(uint(a))<<32) | ulong(uint(s)); }
uint gBubbleIndex(long id, device const GBubble *b, uint n) {
    for(uint i=0;i<n;++i) if(b[i].identity.x==id) return i;
    return n;
}
uint gSegmentIndex(long id, device const GSegment *s, uint n) {
    for(uint i=0;i<n;++i) if(s[i].identity.x==id) return i;
    return n;
}
float2 gFallback(GBubble bubble,GSegment segment,float2 a,float2 b) {
    float sign=segment.flags.z ? segment.collision.x : (((bubble.identity.x^segment.identity.x)&1)==0 ? 1.0f:-1.0f);
    return gNormal(float2(-(b-a).y,(b-a).x),float2(0,1))*sign;
}
GContact gBB(GBubble a,GBubble b,float2 ca,float2 cb) {
    GContact c={}; float2 delta=cb-ca;
    float2 normal=gNormal(delta,a.identity.x<=b.identity.x ? float2(1,0):float2(-1,0));
    c.identity=ulong2(gPairID(a.identity.x,b.identity.x),2);
    c.bubbles=long2(a.identity.x,b.identity.x);
    c.geometry=float4(normal,ca+normal*a.physical.z);
    c.timing.x=a.physical.z+b.physical.z-gLength(delta);
    return c;
}
GContact gBS(GBubble bubble,GSegment segment,float2 center) {
    GContact c={}; float2 q=gClosest(center,segment.current.xy,segment.current.zw);
    float2 fallback=gFallback(bubble,segment,segment.current.xy,segment.current.zw);
    float2 normal=segment.flags.z ? fallback:gNormal(center-q,fallback);
    c.identity=ulong2(gSegmentID(bubble.identity.x,segment.identity.x),5 | (segment.flags.z ? 16:0));
    c.bubbles.x=bubble.identity.x; c.segmentAndAge.x=segment.identity.x;
    c.geometry=float4(normal,q); c.timing.x=bubble.physical.z-gLength(center-q);
    c.timing.z=segment.flags.z ? segment.collision.x:0;
    return c;
}

// Single ordered writer matches CPU dictionary last-write semantics, including
// collisions caused by the CPU's historical 32-bit contact-key encoding.
void gInsert(GContact c,device GContact *out,device GControl &control,uint capacity,uint upper) {
    for(uint i=0;i<control.counts.y;++i) if(out[i].identity.x==c.identity.x) {out[i]=c;return;}
    if(control.counts.y>=capacity) { control.flags.x=1;control.required.y=upper;return; }
    uint i=control.counts.y++;
    while(i>0 && out[i-1].identity.x>c.identity.x) {out[i]=out[i-1];--i;}
    out[i]=c;
}

#define GARGS device const GBubble *b [[buffer(0)]], device const float2 *start [[buffer(1)]], \
 device const float2 *velocity [[buffer(2)]], device const GSegment *s [[buffer(3)]], \
 device const GContact *old [[buffer(4)]], device float2 *predicted [[buffer(5)]], \
 device float2 *guarded [[buffer(6)]], device uint4 *pairs [[buffer(7)]], \
 device GContact *contacts [[buffer(8)]], device GEvent *events [[buffer(9)]], \
 device uint *labels [[buffer(10)]], device uint *touched [[buffer(11)]], \
 device uint4 *components [[buffer(12)]], device GControl &control [[buffer(13)]], \
 constant GParameters &p [[buffer(14)]], uint tid [[thread_position_in_grid]]

// Exact center-line crossing polynomial from ReferenceCenterSegmentTOI.
bool gCenterCrossing(float2 p0,float2 end,GSegment s,float tolerance) {
    float2 dp=end-p0,a0=s.previous.xy,da=s.current.xy-a0;
    float2 v0=s.previous.zw-a0,dv=(s.current.zw-s.current.xy)-v0,u0=p0-a0,du=dp-da;
    float c0=gCross(u0,v0),c1=gCross(du,v0)+gCross(u0,dv),c2=gCross(du,dv);
    float epsilon=max(abs(tolerance),1e-7f); float2 roots; uint count;
    if(abs(c2)<=epsilon) {if(abs(c1)<=epsilon)return false;roots=float2(-c0/c1);count=1;}
    else {float disc=c1*c1-4*c2*c0;if(disc < -epsilon)return false;float r=sqrt(max(0.0f,disc));
        roots=float2((-c1-r)/(2*c2),(-c1+r)/(2*c2));if(roots.x>roots.y)roots=roots.yx;count=2;}
    for(uint i=0;i<count;++i) {
        float t=roots[i];if(t < -epsilon || t>1+epsilon)continue;t=min(1.0f,max(0.0f,t));
        float2 point=p0+dp*t,a=a0+da*t,edge=v0+dv*t;float square=gDot(edge,edge);
        if(square<=FLT_EPSILON)continue;float projection=gDot(point-a,edge)/square;
        if(projection < -epsilon || projection>1+epsilon)continue;
        float sample=min(.0001f,max(epsilon,.000001f));float beforeT=max(0.0f,t-sample),afterT=min(1.0f,t+sample);
        float before=(c2*beforeT+c1)*beforeT+c0,after=(c2*afterT+c1)*afterT+c0;
        if(abs(before)<=epsilon && abs(after)<=epsilon)continue;
        if(before*after<=epsilon || t==0 || t==1)return true;
    }
    return false;
}

kernel void referencePredict(GARGS) {
    if(tid>=p.counts.x)return;
    if(p.capacities.z==0) {predicted[tid]=start[tid]+velocity[tid]*p.physics.x;guarded[tid]=predicted[tid];return;}
    if(control.flags.x)return;
    // This is a preparation side guard; post-solve polygon/containment guards
    // remain a separate required stage and are not replaced by this kernel.
    float2 end=predicted[tid];uint corrections=0;
    for(uint i=0;i<p.counts.y;++i) {
        GSegment seg=s[i];float2 prevEdge=seg.previous.zw-seg.previous.xy,currentEdge=seg.current.zw-seg.current.xy;
        float2 prevNormal=gNormal(float2(-prevEdge.y,prevEdge.x),float2(0,1));
        float2 currentNormal=gNormal(float2(-currentEdge.y,currentEdge.x),prevNormal);
        if(gCenterCrossing(start[tid],end,seg,p.physics.w)) {
            float desired=gDot(start[tid]-seg.previous.xy,prevNormal)<0 ? -1.0f:1.0f;
            float current=gDot(end-seg.current.xy,currentNormal),margin=max(p.physics.y*2,p.physics.w);
            if(current*desired<margin)end=end+currentNormal*(desired*margin-current);
            ++corrections;
        }
        if(seg.flags.z) {float2 n=currentNormal*seg.collision.x;float side=gDot(end-seg.current.xy,n);
            if(side<0) {end=end-n*side;++corrections;}}
    }
    guarded[tid]=end;touched[tid]=corrections;
}

kernel void referenceEmitCandidatePairs(GARGS) {
    if(tid)return;uint count=0;
    // NaN comparisons can otherwise make invalid geometry look like an empty
    // broad phase. Validate on GPU before filtering any candidate away.
    for(uint i=0;i<p.counts.x;++i) {
        if(!all(isfinite(start[i])) || !all(isfinite(velocity[i])) || !all(isfinite(predicted[i])) ||
           !all(isfinite(b[i].physical)) || !all(isfinite(b[i].angular))) {control.flags.y=1;return;}
    }
    for(uint i=0;i<p.counts.y;++i) {
        if(!all(isfinite(s[i].previous)) || !all(isfinite(s[i].current)) ||
           !all(isfinite(s[i].velocity)) || !all(isfinite(s[i].collision))) {control.flags.y=1;return;}
    }
    for(uint a=0;a<p.counts.x;++a)for(uint other=a+1;other<p.counts.x;++other) {
        float2 amin=min(start[a],predicted[a])-b[a].physical.z,amax=max(start[a],predicted[a])+b[a].physical.z;
        float2 bmin=min(start[other],predicted[other])-b[other].physical.z,bmax=max(start[other],predicted[other])+b[other].physical.z;
        if(all(amin<=bmax)&&all(bmin<=amax)) {if(count<p.counts.w)pairs[count]=uint4(0,a,other,0);++count;}
    }
    // CPU tests all bubble/segment pairs, in segment then bubble ID order.
    for(uint seg=0;seg<p.counts.y;++seg)for(uint a=0;a<p.counts.x;++a) {
        if(count<p.counts.w)pairs[count]=uint4(1,a,seg,0);++count;
    }
    control.counts.x=count;control.required.x=count;
    if(count>p.counts.w)control.flags.x=1;
}

kernel void referenceRefreshContacts(GARGS) {
    if(tid || control.flags.x)return;
    for(uint i=0;i<p.counts.z;++i) {
        GContact prior=old[i];uint a=gBubbleIndex(prior.bubbles.x,b,p.counts.x);if(a==p.counts.x)continue;
        GContact c;float speed;
        if((prior.identity.y&1)==0) {if(!(prior.identity.y&2))continue;uint other=gBubbleIndex(prior.bubbles.y,b,p.counts.x);if(other==p.counts.x)continue;
            c=gBB(b[a],b[other],predicted[a],predicted[other]);speed=gDot(velocity[other]-velocity[a],c.geometry.xy);}
        else {if(!(prior.identity.y&4))continue;uint seg=gSegmentIndex(prior.segmentAndAge.x,s,p.counts.y);if(seg==p.counts.y)continue;
            c=gBS(b[a],s[seg],predicted[a]);speed=gDot(velocity[a]-s[seg].velocity.xy,c.geometry.xy);}
        if(c.timing.x>p.physics.y || (c.timing.x>=-p.physics.z && speed<=0)) {
            c.segmentAndAge.y=prior.segmentAndAge.y+1;
            c.identity.y=(c.identity.y&~16ul)|(prior.identity.y&16ul);c.timing.z=prior.timing.z;
            gInsert(c,contacts,control,p.capacities.x,p.limits.z);if(control.flags.x)return;
        }
    }
    for(uint i=0;i<control.counts.x;++i) {uint4 pair=pairs[i];
        GContact c=pair.x==0 ? gBB(b[pair.y],b[pair.z],predicted[pair.y],predicted[pair.z]):gBS(b[pair.y],s[pair.z],predicted[pair.y]);
        if(c.timing.x>p.physics.y) {gInsert(c,contacts,control,p.capacities.x,p.limits.z);if(control.flags.x)return;}
    }
}

float gCircleFraction(float2 origin,float2 movement,float2 center,float radius) {
    float2 relative=origin-center;float a=gDot(movement,movement);if(a<=FLT_EPSILON)return -1;
    float q=2*gDot(relative,movement),c=gDot(relative,relative)-radius*radius,disc=q*q-4*a*c;
    if(disc<0)return -1;float t=(-q-sqrt(disc))/(2*a);return t>=0&&t<=1 ? t:-1;
}
float gSegmentTOI(GBubble bubble,float2 begin,float2 end,GSegment seg,constant GParameters &p,
                  thread float2 &normal,thread float2 &point,thread bool &exhausted) {
    float2 movement=end-begin,da=seg.current.xy-seg.previous.xy,db=seg.current.zw-seg.previous.zw;
    if(gDot(da-db,da-db)<=1e-10f) {
        float2 a=seg.previous.xy,bp=seg.previous.zw,relative=movement-da;
        point=gClosest(begin,a,bp);normal=gNormal(begin-point,gFallback(bubble,seg,a,bp));float radius=bubble.physical.z;
        if(gDot(begin-point,begin-point)<=radius*radius)return 0;
        float best=INFINITY;float2 bestNormal=normal,bestPoint=point;
        for(uint i=0;i<2;++i) {float2 endpoint=i ? bp:a;float t=gCircleFraction(begin,relative,endpoint,radius);
            if(t>=0&&t<best){best=t;bestNormal=gNormal(begin+relative*t-endpoint,normal);bestPoint=endpoint;}}
        float2 edge=bp-a;float square=gDot(edge,edge);
        if(square>FLT_EPSILON) {float2 line=gNormal(float2(-edge.y,edge.x),normal);float initial=gDot(begin-a,line),change=gDot(relative,line);
            if(abs(change)>FLT_EPSILON)for(uint i=0;i<2;++i) {float signedRadius=i ? -radius:radius,t=(signedRadius-initial)/change;
                if(t<0||t>1||t>=best)continue;float projection=gDot(begin+relative*t-a,edge)/square;
                if(projection<0||projection>1)continue;best=t;bestNormal=line*(signedRadius<0 ? -1.0f:1.0f);bestPoint=a+edge*projection;}}
        if(isfinite(best)) {normal=bestNormal;point=bestPoint+da*best;return best;}return -1;
    }
    float bound=gLength(movement)+max(gLength(da),gLength(db)),t=0;
    for(uint i=0;i<p.limits.x;++i) {float2 center=begin+movement*t,a=seg.previous.xy+da*t,bp=seg.previous.zw+db*t;
        point=gClosest(center,a,bp);normal=gNormal(center-point,gFallback(bubble,seg,a,bp));float distance=gLength(center-point);
        if(distance<=bubble.physical.z+p.physics.y)return t;
        if(bound<=FLT_EPSILON)return -1;t+=max(p.physics.w,(distance-bubble.physical.z)/bound*.8f);
        if(t>1)return -1;if(i==p.limits.x-1)exhausted=true;
    }
    return -1;
}

kernel void referenceFindTOI(GARGS) {
    if(tid || control.flags.x)return;
    for(uint i=0;i<control.counts.x;++i) {
        uint4 pair=pairs[i];uint a=pair.y,other=pair.z;
        GContact c=pair.x==0 ? gBB(b[a],b[other],start[a],start[other]):gBS(b[a],s[other],start[a]);
        bool active=false;for(uint k=0;k<p.counts.z;++k)if(old[k].identity.x==c.identity.x){active=true;break;}
        if(active)continue;
        float t=-1;float2 normal,point;bool exhausted=false;
        if(pair.x==0) {float2 initial=start[other]-start[a];float radius=b[a].physical.z+b[other].physical.z;
            t=gDot(initial,initial)<=radius*radius ? 0:gCircleFraction(initial,(predicted[other]-start[other])-(predicted[a]-start[a]),float2(0),radius);
            if(t>=0)c=gBB(b[a],b[other],start[a]+(predicted[a]-start[a])*t,start[other]+(predicted[other]-start[other])*t);
        } else {t=gSegmentTOI(b[a],start[a],predicted[a],s[other],p,normal,point,exhausted);
            // CPU's initial-overlap candidate uses current segment endpoints;
            // only a nonzero impact overrides point/normal and penetration.
            if(t>0){c.geometry=float4(normal,point);c.timing.x=0;}}
        if(exhausted)++control.flags.z;
        if(t<0 || !isfinite(t))continue;
        GEvent event={};event.contact=c;event.timing=float4(p.physics.x*t,t,0,0);
        uint at=control.counts.z++;
        while(at>0 && (events[at-1].timing.x>event.timing.x ||
            (events[at-1].timing.x==event.timing.x && events[at-1].contact.identity.x>c.identity.x))) {
            events[at]=events[at-1];--at;}
        events[at]=event;
    }
    float groupTime=0;uint groups=0;
    for(uint i=0;i<control.counts.z;++i) {float time=events[i].timing.x;
        if(i==0 || time-groupTime>p.events.x) {groupTime=time;++groups;}
        events[i].grouping.x=groups-1;events[i].timing.z=groupTime;
    }
    // Sort IDs within each group without changing that group's anchor time.
    for(uint i=1;i<control.counts.z;++i) {GEvent event=events[i];uint at=i;
        while(at>0 && events[at-1].grouping.x==event.grouping.x && events[at-1].contact.identity.x>event.contact.identity.x) {
            events[at]=events[at-1];--at;}
        events[at]=event;
    }
    control.grouping=uint4(groups,groups>p.limits.y,0,0);
}

uint gRoot(uint i,device uint *labels) {while(labels[i]!=i)i=labels[i];return i;}
kernel void referenceLabelComponents(GARGS) {
    if(tid || control.flags.x)return;
    // The guard dispatch placed correction counts in touched; consume them
    // before reusing this scratch for CPU's contacted-bubble membership.
    for(uint i=0;i<p.counts.x;++i){control.flags.w+=touched[i];labels[i]=i;touched[i]=0;}
    for(uint i=0;i<control.counts.y;++i){GContact c=contacts[i];uint a=gBubbleIndex(c.bubbles.x,b,p.counts.x);
        uint other=(c.identity.y&2) ? gBubbleIndex(c.bubbles.y,b,p.counts.x):p.counts.x;
        if(a<p.counts.x)touched[a]=1;if(other<p.counts.x)touched[other]=1;
        if(a<p.counts.x&&other<p.counts.x){uint ra=gRoot(a,labels),rb=gRoot(other,labels);if(ra!=rb)labels[rb]=ra;}}
    for(uint i=0;i<p.counts.x;++i)labels[i]=gRoot(i,labels);
    uint count=0;
    for(uint root=0;root<p.counts.x;++root){uint bubbles=0,contactCount=0;
        for(uint i=0;i<p.counts.x;++i)if(touched[i]&&labels[i]==root)++bubbles;
        if(!bubbles)continue;
        for(uint i=0;i<control.counts.y;++i){uint a=gBubbleIndex(contacts[i].bubbles.x,b,p.counts.x);
            uint other=(contacts[i].identity.y&2) ? gBubbleIndex(contacts[i].bubbles.y,b,p.counts.x):p.counts.x;
            if((a<p.counts.x&&labels[a]==root)||(other<p.counts.x&&labels[other]==root))++contactCount;}
        if(count<p.capacities.y)components[count]=uint4(root,bubbles,contactCount,0);++count;
    }
    control.counts.w=count;control.required.z=count;if(count>p.capacities.y)control.flags.x=1;
    // Non-finite preparation cannot be published as a valid frame.
    for(uint i=0;i<p.counts.x;++i)if(!all(isfinite(predicted[i]))||!all(isfinite(guarded[i])))control.flags.y=1;
    for(uint i=0;i<control.counts.y;++i)if(!all(isfinite(contacts[i].geometry))||!all(isfinite(contacts[i].timing)))control.flags.y=1;
    for(uint i=0;i<control.counts.z;++i)if(!all(isfinite(events[i].contact.geometry))||
        !all(isfinite(events[i].contact.timing))||!all(isfinite(events[i].timing)))control.flags.y=1;
}
