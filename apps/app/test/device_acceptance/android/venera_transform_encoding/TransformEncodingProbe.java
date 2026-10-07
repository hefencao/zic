package dev.zic.transformencodeprobe;

import android.app.Instrumentation;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Bundle;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.json.JSONObject;

/** Controlled encoding through the target APK's actual WebView/worker lifecycle. */
public final class TransformEncodingProbe extends Instrumentation {
    private ClassLoader loader;
    private Object unit, runtime;
    private Class<?> resultType, function1, function2;
    private ExecutorService executor;
    private byte[] png;
    private String caseName;
    private final List<HeldEncode> held = new ArrayList<HeldEncode>();
    private final JSONObject proof = new JSONObject();
    private final AtomicInteger discarded = new AtomicInteger();
    private final String modifier = "function modifyImage(image){return image.copyAndRotate90();}";

    @Override public void onCreate(Bundle args) {
        caseName = args.getString("case", "overlap");
        super.onCreate(args);
        start();
    }
    private static void require(boolean ok, String message) {
        if (!ok) throw new AssertionError(message);
    }
    private Class<?> type(String name) throws Exception {
        return Class.forName(name, true, loader);
    }
    private Object get(Object obj, String name) throws Exception {
        Field field = obj.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field.get(obj);
    }
    private Object call(Object obj, String name, Class<?>[] signature, Object... args) throws Exception {
        Method method = obj.getClass().getDeclaredMethod(name, signature);
        method.setAccessible(true);
        try { return method.invoke(obj, args); }
        catch (InvocationTargetException error) { throw new RuntimeException(error.getCause()); }
    }
    private Object function(Class<?> type, InvocationHandler handler) {
        return Proxy.newProxyInstance(loader, new Class<?>[]{type}, handler);
    }
    private final class Reply implements InvocationHandler {
        final CountDownLatch done = new CountDownLatch(1);
        final AtomicInteger count = new AtomicInteger();
        volatile Object value;
        volatile String error;
        volatile long tid;
        @Override public Object invoke(Object proxy, Method method, Object[] args) {
            if (method.getName().equals("success") || method.getName().equals("error")) {
                count.incrementAndGet();
                tid = android.os.Process.myTid();
                if (method.getName().equals("success")) value = args[0];
                else error = (String)args[0];
                done.countDown();
            }
            return unit;
        }
        void await() throws Exception {
            require(done.await(12, TimeUnit.SECONDS), "actual transform did not finish");
            require(count.get() == 1, "transform settled more than once");
        }
    }
    private final class HeldEncode implements InvocationHandler {
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final CountDownLatch exited = new CountDownLatch(1);
        final boolean body;
        final String id;
        volatile Bitmap bitmap;
        volatile Object token;
        volatile long tid;
        HeldEncode(String id, boolean body) { this.id = id; this.body = body; held.add(this); }
        @Override public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            if (!method.getName().equals("invoke")) return unit;
            bitmap = (Bitmap)args[0];
            tid = android.os.Process.myTid();
            entered.countDown();
            try {
                require(release.await(20, TimeUnit.SECONDS), "controlled encoder release missing");
                require(!bitmap.isRecycled(), "Bitmap recycled before encoder returned");
                // A controlled late token deliberately ignores cancellation. The worker
                // must discard it via the original pending body's owner exactly once.
                if (body) token = bodyToken(id);
                return token;
            } finally { exited.countDown(); }
        }
        void awaitEntered() throws Exception {
            require(entered.await(4, TimeUnit.SECONDS), "encoder blocked behind another JavaBridge encode");
            require(!bitmap.isRecycled(), "live encoder lost its Bitmap");
        }
    }
    private Object bodyToken(String id) throws Exception {
        Class<?> type = type("dev.zic.pluginhost.RuntimeServiceBodyReference");
        Constructor<?> ctor = type.getDeclaredConstructor(String.class, String.class, String.class,
            String.class, String.class, String.class, String.class, long.class,
            String.class, String.class, byte[].class);
        ctor.setAccessible(true);
        return ctor.newInstance("native-" + UUID.randomUUID(), UUID.randomUUID().toString(), id,
            "controlled-source", "controlled-runtime", "controlled-revision", "controlled:" + id,
            0L, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "0000000000000000", new byte[0]);
    }
    private Reply invoke(String id, Object encoder) throws Exception {
        Reply reply = new Reply();
        Object discard = function(function1, new InvocationHandler() {
            @Override public Object invoke(Object proxy, Method method, Object[] args) {
                if (method.getName().equals("invoke")) discarded.incrementAndGet();
                return unit;
            }
        });
        call(runtime, "invoke", new Class<?>[]{String.class, String.class, byte[].class,
            resultType, function2, function1}, id, modifier, png,
            function(resultType, reply), encoder, discard);
        return reply;
    }
    private Reply invokeHeld(HeldEncode encode) throws Exception {
        return invoke(encode.id, function(function2, encode));
    }
    private void validatePng(Reply reply) throws Exception {
        reply.await();
        require(reply.error == null && reply.value instanceof byte[], "ordinary PNG transform failed");
        byte[] bytes = (byte[])reply.value;
        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        require(bitmap != null && bitmap.getWidth() == 16 && bitmap.getHeight() == 8,
            "PNG protocol or rotation changed");
        require(bitmap.getPixel(0, 0) == 0xff345678 && bitmap.getPixel(15, 7) == 0xff345678,
            "PNG pixels changed");
        bitmap.recycle();
    }
    private CompletableFuture<?> closeRuntime() throws Exception {
        return (CompletableFuture<?>)call(runtime, "closeWhenDrained", new Class<?>[0]);
    }
    private void awaitRecycled(final Bitmap bitmap) throws Exception {
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (!bitmap.isRecycled() && System.nanoTime() < end) Thread.sleep(10);
        require(bitmap.isRecycled(), "finished transform retained its Bitmap");
    }
    @SuppressWarnings("unchecked") private void requireEmptyWorkers() throws Exception {
        for (Object worker : (List<Object>)get(runtime, "workers")) {
            for (String field : new String[]{"pending", "inputs", "completions"})
                require(((Map<?,?>)get(worker, field)).isEmpty(), "worker leaked " + field);
            require(((Map<?,?>)get(get(worker, "bridge"), "images")).isEmpty(), "worker leaked Bitmaps");
        }
        require(((Map<?,?>)get(runtime, "assignments")).isEmpty(), "runtime leaked assignments");
        require(((Set<?>)get(runtime, "busyWorkers")).isEmpty(), "runtime leaked capacity");
    }
    private void setup() throws Exception {
        Context context = getTargetContext();
        loader = context.getClassLoader();
        unit = type("kotlin.Unit").getField("INSTANCE").get(null);
        resultType = type("dev.zic.pluginhost.NativeDriverResult");
        function1 = type("kotlin.jvm.functions.Function1");
        function2 = type("kotlin.jvm.functions.Function2");
        executor = Executors.newCachedThreadPool();
        Class<?> runtimeType = type("dev.zic.pluginhost.VeneraImageTransformRuntime");
        try {
            Constructor<?> ctor = runtimeType.getDeclaredConstructor(Context.class, String.class,
                int.class, ExecutorService.class);
            ctor.setAccessible(true);
            runtime = ctor.newInstance(context, "controlled-encoding", 1024 * 1024, executor);
            proof.put("borrowedExecutorConstructor", true);
        } catch (NoSuchMethodException baseline) {
            Constructor<?> ctor = runtimeType.getDeclaredConstructor(Context.class, String.class, int.class);
            ctor.setAccessible(true);
            runtime = ctor.newInstance(context, "controlled-encoding", 1024 * 1024);
            proof.put("borrowedExecutorConstructor", false);
        }
        require(((List<?>)get(runtime, "workers")).size() == 2, "isolated capacity changed");
        Bitmap seed = Bitmap.createBitmap(8, 16, Bitmap.Config.ARGB_8888);
        seed.eraseColor(0xff345678);
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        require(seed.compress(Bitmap.CompressFormat.PNG, 100, output), "PNG seed failed");
        seed.recycle();
        png = output.toByteArray();
        Reply first = invoke("preflight-a", null), second = invoke("preflight-b", null);
        validatePng(first); validatePng(second);
        proof.put("bothWorkersPreflightReady", true).put("preflightFinishedTids",
            new org.json.JSONArray().put(first.tid).put(second.tid));
    }
    private void overlap() throws Exception {
        HeldEncode first = new HeldEncode("held", false);
        Reply reply = invokeHeld(first);
        first.awaitEntered();
        Reply second = invoke("independent", null);
        require(second.done.await(4, TimeUnit.SECONDS),
            "second worker callback cannot run while first output encoder is held");
        validatePng(second);
        require(reply.count.get() == 0 && !first.bitmap.isRecycled(), "held encode retired early");
        require(first.tid != second.tid, "encoder still occupies the shared JavaBridge thread");
        proof.put("encoderTid", first.tid).put("JavaBridgeFinishedTid", second.tid)
            .put("independentWorkerFinishedWhileEncodeHeld", true);
        first.release.countDown();
        validatePng(reply);
        awaitRecycled(first.bitmap);
    }
    private void cancelCapacity(boolean body) throws Exception {
        HeldEncode first = new HeldEncode("cancelled", body), second = new HeldEncode("other", body);
        Reply a = invokeHeld(first), b = invokeHeld(second);
        first.awaitEntered(); second.awaitEntered();
        call(runtime, "cancel", new Class<?>[]{String.class}, first.id);
        Reply saturated = invoke("too-early", null);
        saturated.await();
        require("venera-isolated-transform-unavailable".equals(saturated.error),
            "cancel released capacity before physical encoding and JS finished");
        require(a.count.get() == 0 && b.count.get() == 0 && !first.bitmap.isRecycled(),
            "cancel retired live encoder");
        first.release.countDown(); a.await(); awaitRecycled(first.bitmap);
        require("runtime-request-cancelled".equals(a.error), "cancel did not settle once after physical exit");
        require(discarded.get() == (body ? 1 : 0), "cancelled late body token not discarded once");
        validatePng(invoke("after-retirement", null));
        require(b.count.get() == 0 && !second.bitmap.isRecycled(), "another worker was retired by cancel");
        second.release.countDown(); b.await(); awaitRecycled(second.bitmap);
        if (body) require(b.value == second.token && b.error == null, "foreign body authority changed");
        else validatePng(b);
        require(a.count.get() == 1 && discarded.get() == (body ? 1 : 0), "late cancel callback duplicated");
        proof.put("cancelWaitedForPhysicalEncodeAndJS", true).put("capacityHeldUntilFinished", true)
            .put("lateBodyDiscardCount", discarded.get()).put("foreignWorkerPreserved", true);
    }
    private void closeBody() throws Exception {
        HeldEncode first = new HeldEncode("close-a", true), second = new HeldEncode("close-b", true);
        Reply a = invokeHeld(first), b = invokeHeld(second);
        first.awaitEntered(); second.awaitEntered();
        CompletableFuture<?> close = closeRuntime();
        require(close == closeRuntime() && !close.isDone(), "close did not join admitted encoders");
        require(a.count.get() == 0 && b.count.get() == 0 && !first.bitmap.isRecycled() &&
            !second.bitmap.isRecycled(), "close reclaimed live images or emitted early results");
        first.release.countDown();
        require(first.exited.await(4, TimeUnit.SECONDS), "first controlled encoder did not return");
        require(!close.isDone() && !second.bitmap.isRecycled(), "close ignored second live encoder");
        second.release.countDown(); close.get(8, TimeUnit.SECONDS);
        a.await(); b.await();
        require("runtime-closing".equals(a.error) && "runtime-closing".equals(b.error),
            "close delivered late success or lost a pending result");
        require(discarded.get() == 2, "close did not discard each late body token exactly once");
        require(first.bitmap.isRecycled() && second.bitmap.isRecycled(), "close leaked live images");
        require(!executor.isShutdown(), "transform closed its borrowed host executor");
        proof.put("closeJoinedBothPhysicalEncoders", true).put("lateBodyDiscardCount", discarded.get())
            .put("borrowedExecutorStillOpen", true);
    }
    private void encodeError() throws Exception {
        Reply reply = invoke("encode-error", function(function2, new InvocationHandler() {
            @Override public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                throw new IOException("controlled encode failure");
            }
        }));
        reply.await();
        require("venera-operation-failed".equals(reply.error), "encode failure lost typed result");
        validatePng(invoke("after-error", null));
        proof.put("failedEncodeSettledOnceAndWorkerReusable", true);
    }
    private void rejectedExecutor() throws Exception {
        executor.shutdown();
        Reply reply = invoke("executor-rejected", null);
        reply.await();
        require("venera-operation-failed".equals(reply.error), "rejected encoder did not settle as failure");
        proof.put("executorRejectionSettledOnce", true);
    }
    @Override public void onStart() {
        Bundle result = new Bundle(); int code = 0;
        try {
            setup();
            if (caseName.equals("overlap")) overlap();
            else if (caseName.equals("cancel-bytes")) cancelCapacity(false);
            else if (caseName.equals("cancel-body")) cancelCapacity(true);
            else if (caseName.equals("close-body")) closeBody();
            else if (caseName.equals("encode-error")) encodeError();
            else if (caseName.equals("executor-rejected")) rejectedExecutor();
            else throw new AssertionError("unknown case " + caseName);
            closeRuntime().get(8, TimeUnit.SECONDS);
            requireEmptyWorkers();
            proof.put("status", "passed").put("pendingInputsImagesAssignmentsEmpty", true);
            code = -1;
        } catch (Throwable error) {
            error.printStackTrace();
            try { proof.put("status", "failed").put("error", error.toString()); } catch (Exception ignored) {}
        } finally {
            for (HeldEncode encode : held) encode.release.countDown();
            if (runtime != null) try { closeRuntime().get(8, TimeUnit.SECONDS); } catch (Exception ignored) {}
            if (executor != null) {
                executor.shutdown();
                try { executor.awaitTermination(5, TimeUnit.SECONDS); } catch (Exception ignored) {}
            }
        }
        try { proof.put("case", caseName); } catch (Exception ignored) {}
        result.putString("evidence", proof.toString());
        finish(code, result);
    }
}
