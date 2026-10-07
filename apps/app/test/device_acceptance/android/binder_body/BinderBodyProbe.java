package dev.zic.binderbodyprobe;

import android.app.ActivityManager;
import android.app.Instrumentation;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.ServiceConnection;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Bundle;
import android.os.FileObserver;
import android.os.IBinder;
import java.io.*;
import java.lang.reflect.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.json.JSONArray;
import org.json.JSONObject;

public final class BinderBodyProbe extends Instrumentation {
    private ClassLoader loader;
    private Object client;
    private Context context;
    private TrackingContext tracked;
    private File work, packets, payload;
    private FileObserver observer;
    private String name, key, digest, processId, sessionId;
    private final JSONObject proof = new JSONObject();
    private final List<String> packetEvents = Collections.synchronizedList(new ArrayList<String>());
    private final List<Gate> gates = new ArrayList<Gate>();
    private static final int MAX = 32 * 1024 * 1024;
    private static final String SCRIPT = "function modifyImage(image){return image.copyAndRotate90()}";

    private static void require(boolean ok, String text) { if (!ok) throw new AssertionError(text); }
    private Class<?> type(String text) throws Exception { return Class.forName(text, true, loader); }
    private Object get(Object value, String field) throws Exception {
        Field f=value.getClass().getDeclaredField(field); f.setAccessible(true); return f.get(value);
    }
    private Object call(Object value, String method, Class<?>[] signature, Object... args) throws Exception {
        Method m=value.getClass().getDeclaredMethod(method,signature); m.setAccessible(true);
        try { return m.invoke(value,args); }
        catch(InvocationTargetException error) {
            Throwable cause=error.getCause(); if(cause instanceof Exception)throw (Exception)cause;
            if(cause instanceof Error)throw (Error)cause; throw new RuntimeException(cause);
        }
    }
    private static Map<String,Object> map(Object... values) {
        Map<String,Object> result=new LinkedHashMap<String,Object>();
        for(int i=0;i<values.length;i+=2)result.put((String)values[i],values[i+1]); return result;
    }
    private static String hex(byte[] bytes) {
        StringBuilder text=new StringBuilder();for(byte b:bytes)text.append(String.format(Locale.US,"%02x",b&255));return text.toString();
    }
    private static String sha(byte[] bytes) throws Exception {return hex(MessageDigest.getInstance("SHA-256").digest(bytes));}
    private static String sha(File file) throws Exception {
        MessageDigest digest=MessageDigest.getInstance("SHA-256");byte[] chunk=new byte[65536];
        try(InputStream input=new FileInputStream(file)){int size;while((size=input.read(chunk))!=-1)digest.update(chunk,0,size);}return hex(digest.digest());
    }
    private static void await(Callable<Boolean> condition, int seconds, String message) throws Exception {
        long end=System.nanoTime()+TimeUnit.SECONDS.toNanos(seconds);
        while(System.nanoTime()<end){if(condition.call())return;Thread.sleep(2);}throw new AssertionError(message);
    }
    private final class TrackingContext extends ContextWrapper {
        final AtomicInteger binds=new AtomicInteger(),unbinds=new AtomicInteger(),stops=new AtomicInteger();
        TrackingContext(Context base){super(base);}
        @Override public Context getApplicationContext(){return this;}
        @Override public boolean bindService(Intent i,ServiceConnection c,int flags){binds.incrementAndGet();return super.bindService(i,c,flags);}
        @Override public void unbindService(ServiceConnection c){super.unbindService(c);unbinds.incrementAndGet();}
        @Override public boolean stopService(Intent i){stops.incrementAndGet();return super.stopService(i);}
    }
    private final class Reply implements InvocationHandler {
        final CompletableFuture<Object> done=new CompletableFuture<Object>();
        final AtomicInteger count=new AtomicInteger();
        final long started=System.nanoTime();
        long settled;
        volatile String errorCode;
        public Object invoke(Object proxy,Method method,Object[] args) {
            if(method.getName().equals("success")){count.incrementAndGet();settled=System.nanoTime();done.complete(args[0]);}
            if(method.getName().equals("error")){count.incrementAndGet();settled=System.nanoTime();errorCode=String.valueOf(args[0]);done.completeExceptionally(new IllegalStateException(errorCode+":"+args[1]));}
            if(method.getName().equals("notImplemented")){count.incrementAndGet();done.completeExceptionally(new AssertionError("notImplemented"));}
            return null;
        }
    }
    private Reply invoke(final String method,final Object arguments) throws Exception {
        final Reply reply=new Reply();final Class<?> callType=type("io.flutter.plugin.common.MethodCall"),resultType=type("io.flutter.plugin.common.MethodChannel$Result");
        final Object message=callType.getConstructor(String.class,Object.class).newInstance(method,arguments);
        final Object result=Proxy.newProxyInstance(loader,new Class<?>[]{resultType},reply);
        final Throwable[] error=new Throwable[1];
        runOnMainSync(()->{try{call(client,"invoke",new Class<?>[]{callType,resultType},message,result);}catch(Throwable t){error[0]=t;}});
        if(error[0]!=null)throw new RuntimeException(error[0]);return reply;
    }
    private void setup() throws Exception {
        context=getTargetContext();loader=context.getClassLoader();key="binder-body-fixture-"+name;
        work=new File(context.getCacheDir(),"binder-body-fixture-"+UUID.randomUUID());require(work.mkdirs(),"fixture directory unavailable");
        packets=new File(context.getCacheDir(),"zic-plugin-runtime-ipc");packets.mkdirs();
        if(name.equals("host-reopen")){
            byte[] markerBytes;try(InputStream in=new FileInputStream(hostMarker());ByteArrayOutputStream out=new ByteArrayOutputStream()){
                byte[] chunk=new byte[1024];int count;while((count=in.read(chunk))!=-1)out.write(chunk,0,count);markerBytes=out.toByteArray();
            }
            JSONObject marker=new JSONObject(new String(markerBytes,"UTF-8"));File previous=new File(marker.getString("leasePath"));
            require(previous.isFile()&&previous.length()==marker.getLong("length"),"previous host lease was absent before original client startup");
            require(sha(previous).equals(marker.getString("sha256")),"previous host lease changed before startup");
            proof.put("previousLeasePresentAndExactBeforeNewClient",true);
        }
        tracked=new TrackingContext(context);
        Constructor<?> ctor=type("dev.zic.pluginhost.PluginRuntimeServiceClient").getDeclaredConstructor(Context.class);ctor.setAccessible(true);
        final Throwable[] failure=new Throwable[1];
        runOnMainSync(()->{try{client=ctor.newInstance(tracked);}catch(Throwable t){failure[0]=t;}});
        if(failure[0]!=null)throw new RuntimeException(failure[0]);
        observer=new FileObserver(packets.getPath(),FileObserver.MOVED_TO|FileObserver.CREATE|FileObserver.DELETE){
            @Override public void onEvent(int event,String file){if(file!=null&&(file.endsWith(".packet")||file.endsWith(".body")||file.endsWith(".body.part")||file.endsWith(".lease")))packetEvents.add(event+":"+file);}
        };observer.startWatching();
        String source="class BinderBodyFixture extends ComicSource {name='Fixture';key='"+key+"';version='1';url='https://fixture.invalid';explore=[{title:'Fixture',type:'multiPageComicList',load:async(page)=>[]}];comic={onThumbnailLoad:(uri)=>({onResponse:async(input)=>input,modifyImage:'"+SCRIPT+"'})};}";
        payload=new File(work,"fixture.js");try(OutputStream stream=new FileOutputStream(payload)){stream.write(source.getBytes("UTF-8"));}
        digest=sha(payload);
    }
    @SuppressWarnings("unchecked") private void activate() throws Exception {
        Map<String,Object> activation=map("schemaVersion",1,"format","veneraJavaScript","pluginId","venera:binder-body-fixture","pluginVersion","1","payloadPath",payload.getPath(),"payloadByteLength",payload.length(),"payloadSha256",digest,"sourceKey",key,"capabilities",Collections.emptyList(),"limits",map("invocationTimeoutMicros",60000000L,"maxResponseBytes",MAX,"maxConcurrentInvocations",1,"maxRuntimeHeapBytes",64*1024*1024));
        Map<String,Object> result=(Map<String,Object>)invoke("activateVeneraRuntime",activation).done.get(30,TimeUnit.SECONDS);
        processId=(String)result.get("processId");sessionId=(String)result.get("sessionId");require(processId!=null&&sessionId!=null,"activation binding missing");
        IBinder binder=(IBinder)get(client,"serviceBinder");require(binder!=null,"actual bound Binder unavailable");
        proof.put("binderDescriptor",binder.getInterfaceDescriptor()).put("hostPid",android.os.Process.myPid()).put("servicePid",servicePid()).put("processId",processId).put("sessionId",sessionId).put("payloadSha256",digest);
        require(servicePid()!=android.os.Process.myPid(),"Service did not run in its separate Android process");
    }
    private int servicePid() {
        ActivityManager manager=(ActivityManager)context.getSystemService(Context.ACTIVITY_SERVICE);
        List<ActivityManager.RunningAppProcessInfo> rows=manager.getRunningAppProcesses();
        if(rows!=null)for(ActivityManager.RunningAppProcessInfo row:rows)if(row.processName.equals(context.getPackageName()+":zic_plugin_runtime"))return row.pid;
        return -1;
    }
    private static byte[] image(int width) throws Exception {
        Bitmap bitmap=Bitmap.createBitmap(width,width+1,Bitmap.Config.ARGB_8888);int[] pixels=new int[width*(width+1)];Random random=new Random(39412);
        for(int i=0;i<pixels.length;i++)pixels[i]=0xff000000|random.nextInt(0x1000000);
        bitmap.setPixels(pixels,0,width,0,0,width,width+1);ByteArrayOutputStream output=new ByteArrayOutputStream();
        require(bitmap.compress(Bitmap.CompressFormat.PNG,100,output),"fixture encoding failed");bitmap.recycle();return output.toByteArray();
    }
    private Reply transform(String id,byte[] bytes,boolean body,boolean isolated) throws Exception {
        Map<String,Object> args=map("uri","https://fixture.invalid/rotate.png","bytes",bytes);
        if(body)args.put("bodyDelivery","sealed-file-v1");if(isolated)args.put("__zicIsolatedModifyImage",SCRIPT);
        Map<String,Object> request=map("schemaVersion",1,"requestId",id,"externalSourceId",key,"operation","transformResource","arguments",args);
        return invoke("invokeExternalRuntime",map("processId",processId,"sessionId",sessionId,"request",request));
    }
    @SuppressWarnings("unchecked") private Object result(Reply reply) throws Exception {
        Map<String,Object> value=(Map<String,Object>)reply.done.get(60,TimeUnit.SECONDS);
        require(Boolean.TRUE.equals(value.get("ok")),"runtime invocation failed: "+value.get("error"));return value.get("payload");
    }
    @SuppressWarnings("unchecked") private Map<String,Object> body(String id,int width,boolean isolated) throws Exception {
        byte[] input=image(width);Object value=result(transform(id,input,true,isolated));require(value instanceof Map,"negotiated body returned bytes");
        Map<String,Object> ref=(Map<String,Object>)value;
        require("sealed-file-v1".equals(ref.get("bodyDelivery"))&&id.equals(ref.get("requestId"))&&key.equals(ref.get("externalSourceId")),"body binding changed");
        require(("venera-runtime-transform-v1:"+digest).equals(ref.get("authorityRevision")),"body payload authority changed");
        proof.put("inputBytes",input.length).put("outputBytes",ref.get("byteLength")).put("width",width);
        require(input.length>512*1024&&((Number)ref.get("byteLength")).longValue()>128*1024,"fixture did not cross packet limits");return ref;
    }
    private Reply beginClaim(Map<String,Object> ref) throws Exception {
        return invoke("claimExternalRuntimeResourceBody",map("processId",processId,"sessionId",sessionId,"requestId",ref.get("requestId"),"reference",ref));
    }
    private File claim(Map<String,Object> ref) throws Exception {return new File((String)beginClaim(ref).done.get(15,TimeUnit.SECONDS));}
    private void release(Map<String,Object> ref,File lease) throws Exception {
        invoke("releaseExternalRuntimeResourceBody",ref).done.get(8,TimeUnit.SECONDS);require(!lease.exists(),"physical body lease was not released");
    }
    private File unclaimed(Map<String,Object> ref){return new File(packets,ref.get("ownerId")+"-"+ref.get("bodyId")+".body");}
    private List<File> matching(Map<String,Object> ref) {
        List<File> found=new ArrayList<File>();File[] rows=packets.listFiles();if(rows!=null)for(File file:rows)if(file.getName().contains(String.valueOf(ref.get("bodyId"))))found.add(file);return found;
    }
    private final class Gate {
        final CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
        Gate() throws Exception {
            gates.add(this);((ExecutorService)get(client,"responseExecutor")).execute(()->{
                entered.countDown();try{require(release.await(90,TimeUnit.SECONDS),"fixture response release missing");}catch(InterruptedException t){throw new RuntimeException(t);}
            });require(entered.await(3,TimeUnit.SECONDS),"original response executor did not enter fixture gate");
        }
    }
    private void cancel(Map<String,Object> ref) throws Exception {
        invoke("cancelExternalRuntime",map("processId",processId,"sessionId",sessionId,"requestId",ref.get("requestId"))).done.get(8,TimeUnit.SECONDS);
    }
    private void requireCancelled(Reply reply) throws Exception {
        try{reply.done.get(15,TimeUnit.SECONDS);throw new AssertionError("cancelled claim published a body");}catch(ExecutionException expected){}
        require("runtime-body-cancelled".equals(reply.errorCode)&&reply.count.get()==1,"claim did not settle once as cancelled");
    }
    private void normal() throws Exception {
        byte[] input=image(1024);List<String> planes=new ArrayList<String>();
        for(boolean isolated:new boolean[]{false,true}){
            byte[] old=(byte[])result(transform("legacy-"+isolated,input,false,isolated));
            Map<String,Object> ref=body("sealed-"+isolated,1024,isolated);File lease=claim(ref);
            require(sha(old).equals(sha(lease))&&old.length==lease.length(),"body carrier changed complete encoded bytes");
            Bitmap transformed=BitmapFactory.decodeFile(lease.getPath()),original=BitmapFactory.decodeByteArray(input,0,input.length);
            require(transformed!=null&&transformed.getWidth()==1025&&transformed.getHeight()==1024,"actual native rotation geometry changed");
            require(transformed.getPixel(1024,0)==original.getPixel(0,0)&&transformed.getPixel(0,1023)==original.getPixel(1023,1024),"actual native rotation pixels changed");
            transformed.recycle();original.recycle();release(ref,lease);planes.add(isolated?"isolated":"canonical");
        }
        proof.put("legacyByteExact",true).put("pixelsExact",true).put("planes",new JSONArray(planes));
    }
    private void beforeClaim() throws Exception {
        Map<String,Object> ref=body("cancel-before-claim",1024,true);Gate gate=new Gate();Reply claim=beginClaim(ref);
        Reply cancellation=invoke("cancelExternalRuntime",map("processId",processId,"sessionId",sessionId,"requestId",ref.get("requestId")));
        require(!claim.done.isDone(),"held claim settled before original executor exit");gate.release.countDown();requireCancelled(claim);cancellation.done.get(8,TimeUnit.SECONDS);
        require(matching(ref).isEmpty(),"cancel-before-claim left a body");proof.put("claimResultCount",claim.count.get()).put("unpublishedFilesRemaining",0);
    }
    private void duringClaim() throws Exception {
        Map<String,Object> ref=body("cancel-hash",2048,true);Reply claim=beginClaim(ref);
        AtomicBoolean observed=new AtomicBoolean();
        await(()->{for(Map.Entry<Thread,StackTraceElement[]> row:Thread.getAllStackTraces().entrySet())if(row.getKey().getName().equals("zic-plugin-runtime-response"))for(StackTraceElement frame:row.getValue())if(frame.getClassName().equals("dev.zic.pluginhost.RuntimeServicePacketFiles")&&frame.getMethodName().equals("claimBody")){observed.set(true);return true;}return claim.done.isDone();},5,"claim never entered physical integrity read");
        require(observed.get()&&!claim.done.isDone(),"hash cancellation sample did not observe active physical claim");
        cancel(ref);requireCancelled(claim);require(matching(ref).isEmpty(),"hash cancellation left body/lease");proof.put("physicalHashObserved",true).put("claimResultCount",claim.count.get()).put("unpublishedFilesRemaining",0);
    }
    private void closeClaim() throws Exception {
        Map<String,Object> ref=body("close-claim",1024,true);Gate gate=new Gate();Reply claim=beginClaim(ref);
        runOnMainSync(()->{try{call(client,"shutdown",new Class<?>[0]);}catch(Exception e){throw new RuntimeException(e);}});
        Thread.sleep(2300);require(!claim.done.isDone()&&!((ExecutorService)get(client,"responseExecutor")).isTerminated(),"shutdown dropped admitted host claim");
        gate.release.countDown();requireCancelled(claim);
        await(()->((ExecutorService)get(client,"responseExecutor")).isTerminated(),8,"host response executor did not physically drain");
        require(matching(ref).isEmpty(),"host shutdown left claim files");proof.put("admittedClaimDrained",true).put("claimResultCount",claim.count.get()).put("unpublishedFilesRemaining",0);
    }
    private void closeDuringHash() throws Exception {
        Map<String,Object> ref=body("close-hash",2048,true);Reply claim=beginClaim(ref);AtomicBoolean observed=new AtomicBoolean();
        await(()->{for(Map.Entry<Thread,StackTraceElement[]> row:Thread.getAllStackTraces().entrySet())if(row.getKey().getName().equals("zic-plugin-runtime-response"))for(StackTraceElement frame:row.getValue())if(frame.getClassName().equals("dev.zic.pluginhost.RuntimeServicePacketFiles")&&frame.getMethodName().equals("claimBody")){observed.set(true);return true;}return claim.done.isDone();},5,"close sample did not enter physical integrity read");
        require(observed.get()&&!claim.done.isDone(),"close sample did not observe active physical claim");
        runOnMainSync(()->{try{call(client,"shutdown",new Class<?>[0]);}catch(Exception e){throw new RuntimeException(e);}});
        requireCancelled(claim);await(()->((ExecutorService)get(client,"responseExecutor")).isTerminated(),8,"physical hash close did not drain");
        require(matching(ref).isEmpty(),"physical hash close left body/lease");proof.put("physicalHashObserved",true).put("claimResultCount",claim.count.get()).put("unpublishedFilesRemaining",0);
    }
    private void sessionCloseRead() throws Exception {
        Map<String,Object> ref=body("session-close-read",1024,true);File lease=claim(ref);
        try(RandomAccessFile input=new RandomAccessFile(lease,"r")){
            byte[] first=new byte[65536];input.readFully(first);
            invoke("closeExternalRuntime",map("processId",processId,"sessionId",sessionId)).done.get(10,TimeUnit.SECONDS);
            require(lease.isFile(),"production session close removed admitted lease");
            MessageDigest actual=MessageDigest.getInstance("SHA-256");actual.update(first);byte[] chunk=new byte[65536];int size;while((size=input.read(chunk))!=-1)actual.update(chunk,0,size);
            require(ref.get("sha256").equals(hex(actual.digest())),"already-open body read changed after actual session close");
        }
        release(ref,lease);proof.put("claimAndOpenReadSurviveActualSessionClose",true).put("releaseRemovesLease",true);
    }
    private void serviceLoss() throws Exception {
        Map<String,Object> ref=body("source-loss-claimed",1024,true);File lease=claim(ref);String expected=(String)ref.get("sha256");String oldProcess=processId;int oldPid=servicePid();
        try(RandomAccessFile input=new RandomAccessFile(lease,"r")){
            byte[] first=new byte[65536];input.readFully(first);android.os.Process.killProcess(oldPid);
            await(()->get(client,"serviceMessenger")==null,8,"actual Binder loss was not observed");require(lease.isFile(),"source death removed admitted host lease");
            activate();require(!oldProcess.equals(processId)&&servicePid()!=oldPid,"source generation was not recreated by explicit activation");require(lease.isFile(),"new service bootstrap removed admitted lease");
            MessageDigest actual=MessageDigest.getInstance("SHA-256");actual.update(first);byte[] chunk=new byte[65536];int size;while((size=input.read(chunk))!=-1)actual.update(chunk,0,size);
            require(expected.equals(hex(actual.digest())),"already-open physical read changed after source restart");
        }
        release(ref,lease);proof.put("sourceOldPid",oldPid).put("sourceNewPid",servicePid()).put("sourceOldProcessId",oldProcess).put("claimAndOpenReadSurviveActualSourceDeathAndRestart",true);
    }
    private void producerLoss() throws Exception {
        Reply reply=transform("source-loss-producing",image(2048),true,true);int oldPid=servicePid();String oldProcess=processId;
        await(()->{File[] rows=packets.listFiles();if(rows!=null)for(File file:rows)if(file.getName().endsWith(".body.part"))return true;return false;},15,"actual body producer did not open a partial file");
        android.os.Process.killProcess(oldPid);
        try{reply.done.get(10,TimeUnit.SECONDS);throw new AssertionError("killed producer published a response");}catch(ExecutionException expected){}
        require(reply.count.get()==1&&reply.errorCode.startsWith("runtime-service-"),"killed producer did not settle once at Binder loss");
        activate();require(!oldProcess.equals(processId),"producer loss did not establish a new generation");
        File[] rows=packets.listFiles();if(rows!=null)for(File file:rows)require(!file.getName().endsWith(".body.part")&&!file.getName().endsWith(".body"),"new service left killed producer files");
        Map<String,Object> ref=body("after-producer-loss",1024,true);File lease=claim(ref);release(ref,lease);
        proof.put("producerPartialObserved",true).put("producerReplyCount",reply.count.get()).put("producerLossError",reply.errorCode).put("nextGenerationWorks",true);
    }
    private File hostMarker(){return new File(context.getFilesDir(),"zic-binder-body-host-loss-fixture.json");}
    private void hostStage() throws Exception {
        Map<String,Object> ref=body("host-loss-stage",1024,true);File lease=claim(ref);
        JSONObject marker=new JSONObject().put("hostPid",android.os.Process.myPid()).put("leasePath",lease.getPath()).put("sha256",ref.get("sha256")).put("length",lease.length());
        try(OutputStream stream=new FileOutputStream(hostMarker())){stream.write(marker.toString().getBytes("UTF-8"));}
        proof.put("hostLossStage",marker).put("leasePreservedForNextHostProcess",true);
    }
    private void hostReopen() throws Exception {
        byte[] bytes;try(InputStream in=new FileInputStream(hostMarker());ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] c=new byte[1024];int n;while((n=in.read(c))!=-1)out.write(c,0,n);bytes=out.toByteArray();}
        JSONObject marker=new JSONObject(new String(bytes,"UTF-8"));File lease=new File(marker.getString("leasePath"));
        require(marker.getInt("hostPid")!=android.os.Process.myPid(),"host process did not actually change");
        await(()->!lease.exists(),8,"new host did not retire previous process lease");require(hostMarker().delete(),"host fixture marker cleanup failed");
        proof.put("oldHostPid",marker.getInt("hostPid")).put("newHostPid",android.os.Process.myPid()).put("oldHostLeaseRetired",true);
    }
    private void rpcTimeout() throws Exception {
        Gate gate=new Gate();Reply reply=transform("rpc-timeout",image(1024),true,true);
        await(()->{File[] rows=packets.listFiles();if(rows!=null)for(File file:rows)if(file.getName().endsWith(".body"))return true;return false;},15,"source did not seal the timeout body");
        try{reply.done.get(75,TimeUnit.SECONDS);throw new AssertionError("held host reply escaped its actual RPC timeout");}catch(ExecutionException expected){}
        require("runtime-service-timeout".equals(reply.errorCode)&&reply.count.get()==1,"actual RPC timer result wrong");
        long elapsed=TimeUnit.NANOSECONDS.toMillis(reply.settled-reply.started);require(elapsed>=64000&&elapsed<71000,"fixture did not use the original 65s timer");
        gate.release.countDown();await(()->{File[] rows=packets.listFiles();if(rows!=null)for(File file:rows)if(file.getName().endsWith(".body")||file.getName().endsWith(".packet"))return false;return true;},10,"late timeout reply did not retire envelope/body");
        Thread.sleep(250);require(reply.count.get()==1,"late timeout response settled original RPC twice");proof.put("actualRpcTimeoutMillis",elapsed).put("resultCount",reply.count.get()).put("lateEnvelopeAndUnclaimedBodyRetired",true);
    }
    private void cleanup() {
        for(Gate gate:gates)gate.release.countDown();
        if(client!=null)try{runOnMainSync(()->{try{call(client,"shutdown",new Class<?>[0]);}catch(Exception ignored){}});await(()->((ExecutorService)get(client,"responseExecutor")).isTerminated(),8,"client cleanup did not drain");}catch(Exception error){try{proof.put("cleanupError",error.toString());}catch(Exception ignored){}}
        if(observer!=null)observer.stopWatching();if(work!=null)remove(work);if(key!=null)context.deleteSharedPreferences("zic_venera_"+key);
    }
    private static void remove(File file){File[] rows=file.listFiles();if(rows!=null)for(File child:rows)remove(child);file.delete();}
    @Override public void onCreate(Bundle args){name=args.getString("case","normal");super.onCreate(args);start();}
    @Override public void onStart(){int code=0;Bundle evidence=new Bundle();
        try{setup();if(name.equals("host-reopen"))hostReopen();else{activate();
            switch(name){case "normal":normal();break;case "cancel-before-claim":beforeClaim();break;case "cancel-during-hash":duringClaim();break;case "close-claim":closeClaim();break;case "close-during-hash":closeDuringHash();break;case "session-close-read":sessionCloseRead();break;case "source-loss":serviceLoss();break;case "producer-loss":producerLoss();break;case "host-stage":hostStage();break;case "rpc-timeout":rpcTimeout();break;default:throw new AssertionError("unknown case "+name);}}
            proof.put("case",name).put("status","passed");code=-1;
        }catch(Throwable error){error.printStackTrace();try{proof.put("case",name).put("status","failed").put("error",error.toString());}catch(Exception ignored){}}
        finally{cleanup();try{proof.put("actualAndroidBinds",tracked==null?0:tracked.binds.get()).put("actualAndroidUnbinds",tracked==null?0:tracked.unbinds.get()).put("actualAndroidStops",tracked==null?0:tracked.stops.get()).put("fileEvents",new JSONArray(packetEvents));if(proof.has("cleanupError")){proof.put("status","failed");code=0;}}catch(Exception ignored){}}
        evidence.putString("evidence",proof.toString());finish(code,evidence);
    }
}
