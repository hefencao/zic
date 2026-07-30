package eu.kanade.tachiyomi.network

import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response
import rx.Observable
import rx.Producer
import rx.Subscription

@Deprecated("Use suspend APIs instead")
fun Call.asObservable(): Observable<Response> = Observable.unsafeCreate { subscriber ->
    val call = clone()
    val arbiter = object : Producer, Subscription {
        private val started = AtomicBoolean()

        override fun request(count: Long) {
            if (count == 0L || !started.compareAndSet(false, true)) return
            try {
                val response = call.execute()
                if (!subscriber.isUnsubscribed) {
                    subscriber.onNext(response)
                    subscriber.onCompleted()
                } else {
                    response.close()
                }
            } catch (error: Throwable) {
                if (!subscriber.isUnsubscribed) subscriber.onError(error)
            }
        }

        override fun unsubscribe() = call.cancel()
        override fun isUnsubscribed(): Boolean = call.isCanceled()
    }
    subscriber.add(arbiter)
    subscriber.setProducer(arbiter)
}

@Deprecated("Use suspend APIs instead")
fun Call.asObservableSuccess(): Observable<Response> = asObservable().doOnNext { response ->
    if (!response.isSuccessful) {
        val code = response.code
        response.close()
        throw IOException("HTTP $code")
    }
}

suspend fun Call.await(): Response = suspendCoroutine { continuation ->
    enqueue(object : Callback {
        override fun onFailure(call: Call, error: IOException) {
            continuation.resumeWithException(error)
        }

        override fun onResponse(call: Call, response: Response) {
            continuation.resume(response)
        }
    })
}

suspend fun Call.awaitSuccess(): Response {
    val response = await()
    if (response.isSuccessful) return response
    val code = response.code
    response.close()
    throw IOException("HTTP $code")
}
