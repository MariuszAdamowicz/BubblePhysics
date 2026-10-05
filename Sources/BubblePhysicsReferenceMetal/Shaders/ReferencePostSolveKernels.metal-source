// Compiled with the reference operator and geometry sources. All frame math is
// GPU work; the CPU only supplies immutable input, sizes resources and publishes.
#include <metal_stdlib>
using namespace metal;
// Xcode also compiles .copy Metal resources into a default metallib. Helpers
// are available only in the explicitly assembled runtime library, preventing
// standalone compilation errors and duplicate exported operator kernels.
#if defined(REFERENCE_WORLD_RUNTIME)
struct WParameters {
    uint4 counts; // bubbles, segments, prior contacts, capacity
    float4 physics; // dt, stiffness, nonlinear stiffening, contact damping
    float4 damping; // linear, angular, surface friction, angular coupling
    float4 tolerances; // contact, separation, position, stress
    float4 shape; // max edge, tension, PCG tolerance, simultaneous tolerance
    uint4 limits; // Newton, PCG, TOI, event groups
};
struct WReport { uint4 counts; float4 quality; float4 components; };
struct WControl {
    WReport solver;
    uint4 work; // candidate bubble pairs, generated, TOI tests, CCD exhaustion
    uint4 events; // guard count, event groups, substeps, event-limit flag
    uint4 failure; // non-finite, overflow, required capacity, failed guard
};
#define WARGS device GBubble *b [[buffer(0)]], device const float2 *input [[buffer(1)]], \
    device const float2 *inputVelocity [[buffer(2)]], device const GSegment *segments [[buffer(3)]], \
    device const GContact *prior [[buffer(4)]], device float2 *v [[buffer(5)]], \
    device GContact *c [[buffer(6)]], device GSegment *intervalSegments [[buffer(7)]], \
    device GEvent *events [[buffer(8)]], device uint *labels [[buffer(9)]], \
    device WControl &control [[buffer(10)]], device const uint2 *ranges [[buffer(11)]], \
    device float2 *points [[buffer(12)]], device float4 *render [[buffer(13)]], \
    constant WParameters &p [[buffer(14)]], uint tid [[thread_position_in_grid]]

float wNorm(device const float2 *a,uint n) {float sum=0;for(uint i=0;i<n;++i)sum+=gDot(a[i],a[i]);return sqrt(sum);}
void wInsert(GContact value,device GContact *out,thread uint &count) {
    uint at=0;while(at<count&&out[at].identity.x<value.identity.x)++at;
    if(at<count&&out[at].identity.x==value.identity.x){out[at]=value;return;}
    for(uint i=count;i>at;--i)out[i]=out[i-1];out[at]=value;++count;
}
uint wRefresh(device const GBubble *b,device const GSegment *s,device const float2 *end,
    device const float2 *velocity,device const GContact *old,uint count,device GContact *out,WParameters p,
    thread bool &valid) {
    uint result=0;
    for(uint i=0;i<count;++i){GContact previous=old[i];uint a=gBubbleIndex(previous.bubbles.x,b,p.counts.x);
        if(a==p.counts.x)continue;GContact next;float speed;
        if(previous.identity.y&1){uint k=gSegmentIndex(previous.segmentAndAge.x,s,p.counts.y);if(k==p.counts.y)continue;
            next=gBS(b[a],s[k],end[a]);speed=gDot(velocity[a]-s[k].velocity.xy,next.geometry.xy);}
        else {uint other=gBubbleIndex(previous.bubbles.y,b,p.counts.x);if(other==p.counts.x)continue;
            next=gBB(b[a],b[other],end[a],end[other]);speed=gDot(velocity[other]-velocity[a],next.geometry.xy);}
        // Check before lifecycle comparisons: -Inf penetration must not silently
        // discard an active contact and turn an invalid solve into success.
        if(!all(isfinite(next.geometry))||!all(isfinite(next.timing))||!isfinite(speed)){valid=false;return 0;}
        if(next.timing.x>p.tolerances.x||(next.timing.x>=-p.tolerances.y&&speed<=0)){
            next.segmentAndAge.y=previous.segmentAndAge.y+1;
            next.identity.y=(next.identity.y&~16ul)|(previous.identity.y&16ul);next.timing.z=previous.timing.z;
            wInsert(next,out,result);}}
    return result;
}
ReferenceOperatorParameters wOperator(WParameters p,uint count,float dt) {
    ReferenceOperatorParameters result;result.counts=uint4(p.counts.x,count,0,0);
    result.physics=float4(dt,p.physics.yzw);result.drag=float4(p.damping.x,0,0,0);return result;
}
float wResidual(device const GBubble *b,device const float2 *start,device const float2 *velocity,
    device const GContact *contacts,device const float2 *end,device float2 *out,
    device const float2 *direction,ReferenceOperatorParameters p) {
    for(uint i=0;i<p.counts.x;++i)out[i]=referenceResidual(i,
        reinterpret_cast<device const ReferenceMetalBubble *>(b),start,velocity,
        reinterpret_cast<device const ReferenceMetalContact *>(contacts),end,direction,p,0);
    return wNorm(out,p.counts.x);
}
void wJoin(device uint *labels,device const GBubble *b,uint n,device const GContact *contacts,uint count) {
    for(uint i=0;i<count;++i){if(!(contacts[i].identity.y&2))continue;
        uint a=gBubbleIndex(contacts[i].bubbles.x,b,n),other=gBubbleIndex(contacts[i].bubbles.y,b,n);
        if(a<n&&other<n){uint ra=gRoot(a,labels),rb=gRoot(other,labels);if(ra!=rb)labels[rb]=ra;}}
}
void wAnnotate(device const GBubble *b,device const GSegment *segments,device const float2 *end,
    device GContact *contacts,uint count,WParameters p) {
    for(uint i=0;i<count;++i){GContact x=contacts[i];uint a=gBubbleIndex(x.bubbles.x,b,p.counts.x);
        uint other=(x.identity.y&2)?gBubbleIndex(x.bubbles.y,b,p.counts.x):p.counts.x;
        float compression=0;
        if(other<p.counts.x){float2 delta=end[other]-end[a];float distance=gLength(delta),ra=b[a].physical.z,rb=b[other].physical.z;
            float2 normal=gNormal(delta,b[a].identity.x<=b[other].identity.x?float2(1,0):float2(-1,0));
            compression=max(0.0f,ra+rb-distance);
            float ka=max(referenceMinimumMass,b[a].physical.w*ra),kb=max(referenceMinimumMass,b[other].physical.w*rb);
            x.compression.y=compression*kb/(ka+kb);x.compression.z=compression*ka/(ka+kb);x.geometry.xy=normal;
            float plane=ra-x.compression.y;
            if(distance>FLT_EPSILON){float inset=max(p.tolerances.z,min(ra,rb)*.01f);
                plane=min(min(ra-inset,distance+rb-inset),max(max(-ra+inset,distance-rb+inset),plane));
                x.timing.w=min(sqrt(max(0.0f,ra*ra-plane*plane)),sqrt(max(0.0f,rb*rb-(plane-distance)*(plane-distance))));}
            else x.timing.w=min(ra,rb);
            x.identity.y|=32ul;x.geometry.zw=end[a]+normal*plane;
        }else{uint k=gSegmentIndex(x.segmentAndAge.x,segments,p.counts.y);
            float2 point=gClosest(end[a],segments[k].current.xy,segments[k].current.zw);
            compression=max(0.0f,b[a].physical.z-gLength(end[a]-point));
            x.geometry.zw=point;x.compression.y=compression;x.compression.z=0;x.identity.y&=~32ul;x.timing.w=0;}
        x.timing.x=compression;x.compression.x=compression;
        float mass=referenceEffectiveMass(b[a].physical.x,other<p.counts.x?b[other].physical.x:0,other<p.counts.x);
        x.response.x=p.physics.y*mass;x.compression.w=x.response.x*compression;contacts[i]=x;}
}

// Ordered GPU orchestration preserves the CPU's component line search and CCD
// activation semantics. Serial orchestration is a correctness baseline; device
// acceptance still measures the entire command buffer, including this dispatch.
WReport wSolve(device GBubble *b,device const GSegment *s,device float2 *v,
    device GContact *c,thread uint &count,device uint *labels,WParameters p,float dt) {
    uint n=p.counts.x,capacity=p.counts.w;
    device float2 *center=v,*velocity=v+n,*start=v+2*n,*startVelocity=v+3*n,*end=v+4*n;
    device float2 *residual=v+5*n,*trial=v+6*n,*trialVelocity=v+7*n,*trialResidual=v+8*n;
    device float2 *solution=v+9*n,*r=v+10*n,*z=v+11*n,*direction=v+12*n,*applied=v+13*n,*diagonal=v+14*n;
    device float2 *mixed=v+15*n,*mixedVelocity=v+16*n;
    device GContact *active=c+2*capacity,*trialContacts=c+3*capacity,*mixedContacts=c+4*capacity;
    WReport report={};
    for(uint i=0;i<n;++i){start[i]=center[i];startVelocity[i]=velocity[i];end[i]=center[i]+velocity[i]*dt;}
    bool valid=true;
    uint activeCount=wRefresh(b,s,end,startVelocity,c,count,active,p,valid);
    if(!valid){report.counts.w|=4;return report;}
    for(uint iteration=0;iteration<p.limits.x;++iteration){
        report.counts.x=iteration+1;
        ReferenceOperatorParameters op=wOperator(p,activeCount,dt);
        float norm=wResidual(b,start,startVelocity,active,end,residual,direction,op);
        if(iteration==0)report.quality.x=norm;report.quality.y=norm;
        if(!isfinite(norm)){report.counts.w|=4;break;}
        if(norm<=p.tolerances.w){report.counts.w|=1;break;}
        for(uint i=0;i<n;++i){float d=gCCDScalar(max(b[i].physical.x,referenceMinimumMass)*
                gCCDScalar(gCCDScalar(2/dt,valid)+max(0.0f,p.damping.x),valid),valid);
            for(uint k=0;k<activeCount;++k){GContact x=active[k];uint a=gBubbleIndex(x.bubbles.x,b,n);
                uint other=(x.identity.y&2)?gBubbleIndex(x.bubbles.y,b,n):n;
                float mass=gCCDScalar(referenceEffectiveMass(b[a].physical.x,other<n?b[other].physical.x:0,other<n),valid);
                float spring=gCCDScalar(gCCDScalar(dt*gCCDScalar(p.physics.y*mass,valid),valid)*.5f,valid);
                float contribution=gCCDScalar(spring+gCCDScalar(p.physics.w*mass,valid),valid);
                if(contribution>0){if(i==a)d=gCCDScalar(d+contribution,valid);if(other<n&&i==other)d=gCCDScalar(d+contribution,valid);}}
            // Preserve failures before max(d, minimumMass) or 1/Inf masks them.
            if(!valid){report.counts.w|=4;return report;}
            diagonal[i]=float2(gCCDScalar(1/max(d,referenceMinimumMass),valid));
            solution[i]=0;r[i]=-residual[i];z[i]=gCCDVector(r[i]*diagonal[i],valid);direction[i]=z[i];
            if(!valid){report.counts.w|=4;return report;}}
        float rz=0;for(uint i=0;i<n;++i)rz+=gDot(r[i],z[i]);
        float threshold=p.shape.z*norm;
        for(uint k=0;k<p.limits.y&&norm>FLT_EPSILON;++k){
            bool nonzero=false;for(uint i=0;i<n;++i)if(gDot(direction[i],direction[i])>0)nonzero=true;
            float denominator=0;
            for(uint i=0;i<n;++i){float2 plus=referenceResidual(i,reinterpret_cast<device const ReferenceMetalBubble *>(b),start,startVelocity,
                    reinterpret_cast<device const ReferenceMetalContact *>(active),end,direction,op,referenceEpsilon);
                float2 minus=referenceResidual(i,reinterpret_cast<device const ReferenceMetalBubble *>(b),start,startVelocity,
                    reinterpret_cast<device const ReferenceMetalContact *>(active),end,direction,op,-referenceEpsilon);
                applied[i]=nonzero?(plus-minus)/(2*referenceEpsilon):float2(0);
                denominator+=gDot(direction[i],applied[i]);}
            if(!isfinite(denominator)||!isfinite(rz)){report.counts.w|=4;break;}
            if(denominator<=FLT_EPSILON)break;
            float alpha=rz/denominator;
            for(uint i=0;i<n;++i){solution[i]+=direction[i]*alpha;r[i]+=applied[i]*-alpha;}
            ++report.counts.y;float rNorm=wNorm(r,n);
            if(!isfinite(rNorm)){report.counts.w|=4;break;}if(rNorm<=threshold)break;
            float next=0;for(uint i=0;i<n;++i){z[i]=r[i]*diagonal[i];next+=gDot(r[i],z[i]);}
            if(!isfinite(next)){report.counts.w|=4;break;}
            for(uint i=0;i<n;++i)direction[i]=z[i]+direction[i]*(next/rz);rz=next;
        }
        bool accepted=false;
        for(uint search=0;search<6;++search){float lambda=1.0f/float(1u<<search);bool finite=true;
            for(uint i=0;i<n;++i){trial[i]=end[i]+solution[i]*lambda;trialVelocity[i]=(trial[i]-start[i])*(2/dt)-startVelocity[i];finite=finite&&all(isfinite(trial[i]));}
            if(!finite)continue;
            uint trialCount=wRefresh(b,s,trial,trialVelocity,active,activeCount,trialContacts,p,valid);
            if(!valid){report.counts.w|=4;return report;}
            wResidual(b,start,startVelocity,trialContacts,trial,trialResidual,direction,wOperator(p,trialCount,dt));
            for(uint i=0;i<n;++i)labels[i]=i;
            wJoin(labels,b,n,active,activeCount);wJoin(labels,b,n,trialContacts,trialCount);
            bool improving=false;
            for(uint i=0;i<n;++i){uint root=gRoot(i,labels);float before=0,after=0;
                for(uint j=0;j<n;++j)if(gRoot(j,labels)==root){before+=gDot(residual[j],residual[j]);after+=gDot(trialResidual[j],trialResidual[j]);}
                bool use=isfinite(after)&&after<before;improving=improving||use;
                mixed[i]=use?trial[i]:end[i];mixedVelocity[i]=(mixed[i]-start[i])*(2/dt)-startVelocity[i];}
            if(!improving)continue;
            uint mixedCount=wRefresh(b,s,mixed,mixedVelocity,active,activeCount,mixedContacts,p,valid);
            if(!valid){report.counts.w|=4;return report;}
            float mixedNorm=wResidual(b,start,startVelocity,mixedContacts,mixed,trialResidual,direction,wOperator(p,mixedCount,dt));
            if(isfinite(mixedNorm)&&mixedNorm<norm){for(uint i=0;i<n;++i)end[i]=mixed[i];
                for(uint k=0;k<mixedCount;++k)active[k]=mixedContacts[k];activeCount=mixedCount;report.quality.y=mixedNorm;accepted=true;break;}
        }
        if(!accepted){++report.counts.z;break;}
    }
    for(uint i=0;i<n;++i){center[i]=end[i];velocity[i]=(end[i]-start[i])*(2/dt)-startVelocity[i];}
    wAnnotate(b,s,end,active,activeCount,p);count=activeCount;for(uint k=0;k<count;++k)c[k]=active[k];
    report.quality.y=wResidual(b,start,startVelocity,active,end,residual,direction,wOperator(p,count,dt));
    if(report.quality.y<=p.tolerances.w)report.counts.w|=1;
    if(!(report.counts.w&1)&&report.counts.x>=p.limits.x)report.counts.w|=2;
    if(!isfinite(report.quality.y))report.counts.w|=4;
    for(uint i=0;i<n;++i){labels[i]=i;labels[n+i]=0;if(!all(isfinite(center[i]))||!all(isfinite(velocity[i])))report.counts.w|=4;}
    wJoin(labels,b,n,c,count);
    for(uint k=0;k<count;++k){GContact x=c[k];uint a=gBubbleIndex(x.bubbles.x,b,n);
        labels[n+a]=1;if(x.identity.y&2)labels[n+gBubbleIndex(x.bubbles.y,b,n)]=1;
        report.quality.z=max(report.quality.z,x.compression.x);report.quality.w=max(report.quality.w,x.compression.y/max(b[a].physical.z,FLT_EPSILON));}
    for(uint root=0;root<n;++root){float sum=0;bool member=false;
        for(uint i=0;i<n;++i)if(labels[n+i]&&gRoot(i,labels)==root){member=true;sum+=gDot(residual[i],residual[i]);}
        if(member){float norm=sqrt(sum);++report.components.x;if(!isfinite(norm)||norm>p.tolerances.w)++report.components.y;
            if(isfinite(norm))report.components.z=max(report.components.z,norm);}}
    return report;
}
void wMerge(WReport next,thread WReport &aggregate,thread bool &hasReport) {
    if(!hasReport){aggregate=next;hasReport=true;return;}
    aggregate.counts.xyz+=next.counts.xyz;
    aggregate.counts.w=((aggregate.counts.w&next.counts.w)&1)|((aggregate.counts.w|next.counts.w)&6);
    aggregate.quality.y=next.quality.y;aggregate.quality.zw=max(aggregate.quality.zw,next.quality.zw);
    aggregate.components=max(aggregate.components,next.components);
}
void wSegments(device const GSegment *source,device GSegment *out,WParameters p,float elapsed,float duration) {
    float f0=min(1.0f,max(0.0f,elapsed/p.physics.x)),f1=min(1.0f,max(0.0f,(elapsed+duration)/p.physics.x));
    for(uint i=0;i<p.counts.y;++i){GSegment x=source[i];float4 begin=x.previous+(x.current-x.previous)*f0,end=x.previous+(x.current-x.previous)*f1;
        x.previous=x.flags.x?begin:end;x.current=end;
        if(x.flags.x)x.velocity.xy=((end.xy-begin.xy)+(end.zw-begin.zw))*.5f/max(duration,FLT_EPSILON);
        else x.velocity=float4(0);out[i]=x;}
}
uint wScan(device const GBubble *b,device const GSegment *s,device const float2 *start,device const float2 *end,
    device const GContact *active,uint activeCount,device GEvent *out,device WControl &control,WParameters p,float duration) {
    uint count=0;bool valid=true;GParameters gp={};gp.physics=float4(duration,p.tolerances.xyz);gp.limits=uint4(p.limits.z,p.limits.w,0,0);
    for(uint type=0;type<2;++type)for(uint first=0;first<(type?p.counts.y:p.counts.x);++first)
        for(uint second=type?0:first+1;second<p.counts.x;++second){uint a=type?second:first,other=type?first:second;
            if(!type){float2 amin=min(start[a],end[a])-b[a].physical.z,amax=max(start[a],end[a])+b[a].physical.z;
                float2 bmin=min(start[other],end[other])-b[other].physical.z,bmax=max(start[other],end[other])+b[other].physical.z;
                if(!(all(amin<=bmax)&&all(bmin<=amax)))continue;++control.work.x;}
            GContact candidate=type?gBS(b[a],s[other],start[a]):gBB(b[a],b[other],start[a],start[other]);
            bool exists=false;for(uint k=0;k<activeCount;++k)if(active[k].identity.x==candidate.identity.x)exists=true;
            if(exists)continue;++control.work.z;
            float fraction=-1;float2 normal,point;bool exhausted=false;
            if(type){fraction=gSegmentTOI(b[a],start[a],end[a],s[other],gp,normal,point,exhausted,valid);
                if(fraction>0){candidate.geometry=float4(normal,point);candidate.timing.x=0;}}
            else {float2 initial=gCCDVector(start[other]-start[a],valid),movement=gCCDVector((end[other]-start[other])-(end[a]-start[a]),valid);
                float radius=gCCDScalar(b[a].physical.z+b[other].physical.z,valid);
                float square=gCCDDot(initial,initial,valid),radiusSquare=gCCDScalar(radius*radius,valid);
                fraction=square<=radiusSquare?0:gCircleFraction(initial,movement,float2(0),radius,valid);
                if(fraction>=0)candidate=gBB(b[a],b[other],start[a]+(end[a]-start[a])*fraction,start[other]+(end[other]-start[other])*fraction);}
            if(exhausted)++control.work.w;
            if(!valid){control.failure.x=1;return 0;}if(fraction<0)continue;
            if(!all(isfinite(candidate.geometry))||!all(isfinite(candidate.timing))){control.failure.x=1;return 0;}
            // CPU stores every event time but candidates[stableKey] is updated
            // in scan order. Even a later event outside the activation window
            // supplies the candidate for earlier events with the same key.
            for(uint k=0;k<count;++k)if(out[k].contact.identity.x==candidate.identity.x)out[k].contact=candidate;
            GEvent event={};event.contact=candidate;event.timing=float4(duration*fraction,0,0,0);
            uint at=count++;while(at>0&&(out[at-1].timing.x>event.timing.x||(out[at-1].timing.x==event.timing.x&&out[at-1].contact.identity.x>candidate.identity.x))){out[at]=out[at-1];--at;}out[at]=event;}
    return count;
}
kernel void referenceAdvanceWorld(WARGS) {
    if(tid)return;control={};control.solver.counts.w=1;
    // Grow before entering any interval. Every possible key fits, including old
    // keys; this is a resource bound, never a semantic contact/event limit.
    ulong required=ulong(p.counts.x)*(p.counts.x?ulong(p.counts.x-1):0)/2+ulong(p.counts.x)*p.counts.y+p.counts.z;
    if(required>p.counts.w){control.failure.y=1;control.failure.z=uint(required);return;}
    uint n=p.counts.x,count=p.counts.z,capacity=p.counts.w;
    for(uint i=0;i<n;++i){v[i]=input[i];v[n+i]=inputVelocity[i];
        if(!all(isfinite(input[i]))||!all(isfinite(inputVelocity[i]))||!all(isfinite(b[i].physical))||!all(isfinite(b[i].angular)))control.failure.x=1;}
    for(uint k=0;k<p.counts.y;++k)if(!all(isfinite(segments[k].previous))||!all(isfinite(segments[k].current))||!all(isfinite(segments[k].velocity)))control.failure.x=1;
    for(uint k=0;k<count;++k)c[k]=prior[k];
    if(control.failure.x)return;
    float elapsed=0,remaining=p.physics.x,epsilon=max(p.tolerances.z,1e-7f);WReport aggregate={};bool hasReport=false;
    while(remaining>epsilon){uint previousCount=count;
        for(uint i=0;i<n;++i){v[17*n+i]=v[i];v[18*n+i]=v[n+i];}
        for(uint k=0;k<count;++k)c[capacity+k]=c[k];
        wSegments(segments,intervalSegments,p,elapsed,remaining);
        WReport tentative=wSolve(b,intervalSegments,v,c,count,labels,p,remaining);
        if(tentative.counts.w&4){control.failure.x=1;return;}
        uint eventCount=wScan(b,intervalSegments,v+17*n,v,c+capacity,previousCount,events,control,p,remaining);
        if(control.failure.x)return;
        if(!eventCount){wMerge(tentative,aggregate,hasReport);++control.events.z;elapsed+=remaining;remaining=0;break;}
        for(uint i=0;i<n;++i){v[i]=v[17*n+i];v[n+i]=v[18*n+i];}
        count=previousCount;for(uint k=0;k<count;++k)c[k]=c[capacity+k];
        float interval=events[0].timing.x,anchor=interval;uint firstCount=1,groups=1,activationCount=1;
        for(uint k=1;k<eventCount;++k){if(events[k].timing.x-anchor>p.shape.w){anchor=events[k].timing.x;++groups;}
            if(groups==1)++firstCount;if(groups<=p.limits.w)activationCount=k+1;}
        if(interval>epsilon){wSegments(segments,intervalSegments,p,elapsed,interval);
            WReport report=wSolve(b,intervalSegments,v,c,count,labels,p,interval);if(report.counts.w&4){control.failure.x=1;return;}
            wMerge(report,aggregate,hasReport);++control.events.z;elapsed+=interval;remaining=max(0.0f,remaining-interval);}
        for(uint k=0;k<firstCount;++k){bool exists=false;for(uint j=0;j<count;++j)if(c[j].identity.x==events[k].contact.identity.x)exists=true;if(!exists)wInsert(events[k].contact,c,count);}
        control.work.y+=firstCount;++control.events.y;
        if(groups>p.limits.w||control.events.y>=p.limits.w){control.events.w=groups>p.limits.w||remaining>epsilon;
            // Match the CPU queue's existing semantic group limit. The event
            // buffer still retains the complete scan; only activation is bounded.
            for(uint k=firstCount;k<activationCount;++k){bool exists=false;for(uint j=0;j<count;++j)if(c[j].identity.x==events[k].contact.identity.x)exists=true;if(!exists)wInsert(events[k].contact,c,count);}
            control.work.y+=activationCount-firstCount;
            if(remaining>epsilon){wSegments(segments,intervalSegments,p,elapsed,remaining);
                WReport report=wSolve(b,intervalSegments,v,c,count,labels,p,remaining);if(report.counts.w&4){control.failure.x=1;return;}
                wMerge(report,aggregate,hasReport);++control.events.z;remaining=0;}break;}
    }
    if(hasReport)control.solver=aggregate;
    // Contact count is stored outside the solver report's quality fields.
    control.failure.z=count;
}

bool wInside(float2 point,device const GSegment *s,uint count,long owner) {
    bool inside=false;
    for(uint k=0;k<count;++k)if(s[k].flags.y&&s[k].identity.y==owner){float2 a=s[k].current.xy,b=s[k].current.zw;
        if((a.y>point.y)!=(b.y>point.y)){float crossing=(b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x;if(point.x<crossing)inside=!inside;}}
    return inside;
}
kernel void referenceApplyCenterGuards(WARGS) {
    if(tid||control.failure.x||control.failure.y)return;uint n=p.counts.x,count=control.failure.z;bool valid=true;
    for(uint i=0;i<n;++i){float2 end=v[i];
        for(uint k=0;k<p.counts.y;++k){GSegment seg=segments[k];float2 prevEdge=gCCDVector(seg.previous.zw-seg.previous.xy,valid),edge=gCCDVector(seg.current.zw-seg.current.xy,valid);
            float2 previousNormal=gCCDNormal(float2(-prevEdge.y,prevEdge.x),float2(0,1),valid),normal=gCCDNormal(float2(-edge.y,edge.x),previousNormal,valid);
            if(gCenterCrossing(input[i],end,seg,p.tolerances.z,valid)){float sign=gCCDDot(gCCDVector(input[i]-seg.previous.xy,valid),previousNormal,valid)<0?-1.0f:1.0f;
                float side=gCCDDot(gCCDVector(end-seg.current.xy,valid),normal,valid),margin=max(p.tolerances.x*2,p.tolerances.z);
                if(side*sign<margin)end=gCCDVector(end+normal*(sign*margin-side),valid);++control.events.x;}
            if(seg.flags.z){float2 allowed=gCCDNormal(float2(-edge.y,edge.x),float2(0,1),valid)*seg.collision.x;
                float side=gCCDDot(gCCDVector(end-seg.current.xy,valid),allowed,valid);if(side<0){end=gCCDVector(end-allowed*side,valid);++control.events.x;}}
        }
        v[i]=end;if(!valid){control.failure.x=1;return;}
    }
    for(uint i=0;i<n;++i)for(uint ownerIndex=0;ownerIndex<p.counts.y;++ownerIndex){GSegment owner=segments[ownerIndex];if(!owner.flags.y)continue;
        bool first=true;for(uint k=0;k<ownerIndex;++k)if(segments[k].flags.y&&segments[k].identity.y==owner.identity.y)first=false;
        if(!first)continue;uint edges=0;for(uint k=0;k<p.counts.y;++k)if(segments[k].flags.y&&segments[k].identity.y==owner.identity.y)++edges;
        if(edges<3||!wInside(v[i],segments,p.counts.y,owner.identity.y))continue;
        float best=INFINITY;float2 point;uint nearest=0;
        for(uint k=0;k<p.counts.y;++k)if(segments[k].flags.y&&segments[k].identity.y==owner.identity.y){float2 q=gClosest(v[i],segments[k].current.xy,segments[k].current.zw);float square=gDot(q-v[i],q-v[i]);
            if(square<best){best=square;point=q;nearest=k;}}
        float2 outward=gNormal(point-v[i],gNormal(segments[nearest].current.xy-v[i],float2(1,0)));
        v[i]=point+outward*max(p.tolerances.x*2,p.tolerances.z);
        float inward=gDot(v[n+i]-segments[nearest].velocity.xy,outward);if(inward<0)v[n+i]-=outward*inward;
        uint kept=0;for(uint k=0;k<count;++k){GContact x=c[k];uint s=(x.identity.y&4)?gSegmentIndex(x.segmentAndAge.x,segments,p.counts.y):p.counts.y;
            if(x.bubbles.x==b[i].identity.x&&s<p.counts.y&&segments[s].flags.y&&segments[s].identity.y==owner.identity.y)continue;c[kept++]=x;}
        count=kept;++control.events.x;
    }
    // Bounded surface friction precedes rotation, exactly as in ReferenceWorld.
    for(uint k=0;k<count;++k){GContact x=c[k];if(!(x.identity.y&1)||x.compression.w<=0)continue;
        uint i=gBubbleIndex(x.bubbles.x,b,n),s=gSegmentIndex(x.segmentAndAge.x,segments,p.counts.y);if(i==n||s==p.counts.y||!segments[s].flags.x)continue;
        float2 tangent=gNormal(float2(x.geometry.y,-x.geometry.x),float2(1,0));
        float speed=gDot(segments[s].velocity.xy-v[n+i],tangent),limit=p.damping.z*x.compression.w*p.physics.x;
        float2 impulse=tangent*min(limit,max(-limit,speed*b[i].physical.x));v[n+i]+=impulse*b[i].physical.y;
        float inertia=max(.5f*b[i].physical.x*b[i].physical.z*b[i].physical.z,FLT_EPSILON);
        b[i].angular.y+=p.damping.w*gCross(x.geometry.zw-v[i],impulse)/inertia;
    }
    for(uint i=0;i<n;++i){b[i].angular.x+=b[i].angular.y*p.physics.x;b[i].angular.y*=exp(-p.damping.y*p.physics.x);
        if(!all(isfinite(v[i]))||!all(isfinite(v[n+i]))||!all(isfinite(b[i].angular)))control.failure.x=1;
        for(uint k=0;k<p.counts.y;++k){GSegment s=segments[k];float2 edge=s.current.zw-s.current.xy;
            if(s.flags.z&&gDot(v[i]-s.current.xy,gNormal(float2(-edge.y,edge.x),float2(0,1))*s.collision.x)<-p.tolerances.z)control.failure.w=1;
            if(s.flags.y){uint edges=0;for(uint j=0;j<p.counts.y;++j)if(segments[j].flags.y&&segments[j].identity.y==s.identity.y)++edges;
                if(edges>=3&&wInside(v[i],segments,p.counts.y,s.identity.y))control.failure.w=1;}}
    }
    control.failure.z=count;
}

float wRadius(uint index,float2 center,float2 direction,device const GBubble *b,device const GSegment *s,
    device const GContact *c,uint count,WParameters p) {
    float radius=b[index].physical.z;
    for(uint k=0;k<count;++k){GContact x=c[k];bool isA=x.bubbles.x==b[index].identity.x;
        if(!isA&&(!(x.identity.y&2)||x.bubbles.y!=b[index].identity.x))continue;
        float2 a,bp,inward;bool finiteSegment=false;
        if(!(x.identity.y&1)&&(x.identity.y&32)&&x.timing.w>0){float2 tangent=gNormal(float2(-x.geometry.y,x.geometry.x),float2(0,1));
            a=x.geometry.zw-tangent*x.timing.w;bp=x.geometry.zw+tangent*x.timing.w;finiteSegment=true;inward=isA?-x.geometry.xy:x.geometry.xy;}
        else if(x.identity.y&1){uint si=gSegmentIndex(x.segmentAndAge.x,s,p.counts.y);if(si<p.counts.y){a=s[si].current.xy;bp=s[si].current.zw;float2 edge=bp-a;
            inward=gNormal(float2(-edge.y,edge.x),x.geometry.xy);if(s[si].flags.z)inward*=s[si].collision.x;else if(gDot(center-a,inward)<0)inward=-inward;finiteSegment=true;}}
        if(finiteSegment){float2 edge=bp-a;float denominator=gCross(direction,edge);
            if(abs(denominator)>1e-6f){float2 offset=a-center;float distance=gCross(offset,edge)/denominator,fraction=gCross(offset,direction)/denominator;
                if(distance>=0&&fraction>=0&&fraction<=1&&distance<radius)radius=max(0.0f,distance-p.tolerances.z);}continue;}
        inward=(x.identity.y&1)?x.geometry.xy:(isA?-x.geometry.xy:x.geometry.xy);
        inward=gNormal(inward,float2(1,0));float slope=gDot(direction,inward);
        if(slope<-FLT_EPSILON){float candidate=max(0.0f,gDot(center-x.geometry.zw,inward)/-slope);if(candidate<radius)radius=candidate;}
    }
    return radius;
}
float2 wProject(float2 point,uint index,float2 center,device const GBubble *b,device const GSegment *s,
    device const GContact *c,uint count,WParameters p) {
    float2 offset=point-center;if(gDot(offset,offset)<=FLT_EPSILON)return center;
    float length=gLength(offset);float2 direction=offset/length;
    return center+direction*min(length,wRadius(index,center,direction,b,s,c,count,p));
}
float wTurn(float2 a,float2 b){if(gDot(a,a)<=FLT_EPSILON||gDot(b,b)<=FLT_EPSILON)return M_PI_F;
    return acos(min(1.0f,max(-1.0f,gDot(gNormal(a,float2(1,0)),gNormal(b,float2(1,0))))));}
float wViolation(float2 before,float2 middle,float2 after,float edge,float turn){float2 incoming=middle-before,outgoing=after-middle;
    return (max(0.0f,gLength(incoming)-edge)+max(0.0f,gLength(outgoing)-edge))/max(edge,FLT_EPSILON)+max(0.0f,wTurn(incoming,outgoing)-turn);}
kernel void referenceGenerateContours(WARGS) {
    if(tid>=p.counts.x||control.failure.x||control.failure.y||control.failure.w)return;
    uint n=ranges[tid].y,offset=ranges[tid].x,contacts=control.failure.z;float2 center=v[tid];float radius=b[tid].physical.z;
    device float2 *out=points+offset;
    for(uint i=0;i<n;++i){float angle=2*M_PI_F*float(i)/float(n);float2 direction=float2(cos(angle),sin(angle));out[i]=center+direction*wRadius(tid,center,direction,b,segments,c,contacts,p);}
    float allowed=p.shape.x+max(p.tolerances.z,p.shape.x*1e-4f),turn=max(2*M_PI_F/float(n)*2.5f,.18f);
    float relaxation=min(.8f,max(.25f,p.shape.y/(p.shape.y+10)));
    for(uint pass=0;pass<12;++pass){bool changed=false;
        for(uint i=0;i<n;++i){float angle=2*M_PI_F*float(i)/float(n);float2 direction=float2(cos(angle),sin(angle));
            float2 target=center+gNormal(out[i]-center,direction)*radius;
            float2 projected=wProject(out[i]+(target-out[i])*.08f,tid,center,b,segments,c,contacts,p);
            if(gLength(projected-out[i])>p.tolerances.z){out[i]=projected;changed=true;}}
        for(uint at=0;at<n;++at){uint middle=(pass%2)?n-1-at:at,before=(middle+n-1)%n,after=(middle+1)%n;
            float2 a=out[before],m=out[middle],z=out[after];float score=wViolation(a,m,z,allowed,turn);if(score<=p.tolerances.z)continue;
            float2 candidate=wProject(m+((a+z)*.5f-m)*relaxation,tid,center,b,segments,c,contacts,p);
            if(wViolation(a,candidate,z,allowed,turn)+p.tolerances.z<score){out[middle]=candidate;changed=true;continue;}
            float2 ac=wProject(a+(m*2-z-a)*(relaxation*.5f),tid,center,b,segments,c,contacts,p);
            float2 zc=wProject(z+(m*2-a-z)*(relaxation*.5f),tid,center,b,segments,c,contacts,p);
            if(wViolation(ac,m,zc,allowed,turn)+p.tolerances.z<score){out[before]=ac;out[after]=zc;changed=true;}}
        for(uint first=0;first<n;++first){uint second=(first+1)%n;float2 delta=out[second]-out[first];float length=gLength(delta);if(length<=allowed)continue;
            float angle=2*M_PI_F*float(second)/float(n);float2 correction=gNormal(delta,float2(cos(angle),sin(angle)))*((length-p.shape.x)*.5f);
            float2 a=wProject(out[first]+correction,tid,center,b,segments,c,contacts,p),z=wProject(out[second]-correction,tid,center,b,segments,c,contacts,p);
            if(gLength(z-a)+p.tolerances.z<length){out[first]=a;out[second]=z;changed=true;}}
        if(!changed)break;
    }
    for(uint i=0;i<n;++i)out[i]=wProject(out[i],tid,center,b,segments,c,contacts,p);
}
kernel void referencePrepareRenderData(WARGS) {
    if(tid||control.failure.x||control.failure.y||control.failure.w)return;
    for(uint i=0;i<p.counts.x;++i){render[i]=float4(v[i],b[i].physical.z,b[i].angular.x);
        for(uint k=0;k<ranges[i].y;++k)if(!all(isfinite(points[ranges[i].x+k])))control.failure.x=1;}
}
#endif
