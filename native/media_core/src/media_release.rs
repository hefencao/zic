//! Process-owned media reclamation, independent of decode/ingress admission.
//! The caller relinquishes each handle once; the worker owns it until drop.

use crate::{ByteSource, Cursor, FrameHandle};
use std::sync::{mpsc, OnceLock};

enum Message {
    Release(Box<FrameHandle>),
    Cursor(RetiredCursor),
    Source(Box<ByteSource>),
    Drain(mpsc::SyncSender<()>),
    #[cfg(test)]
    Pause(mpsc::SyncSender<()>, mpsc::Receiver<()>),
}

struct RetiredCursor(Box<Cursor>);

// A retired cursor is no longer accessed by a decoder. The FFI transfer is
// permitted only after its exact in-flight decode returns; libwebp demux and
// canvas destruction have no thread affinity. Do not make live Cursor Send.
unsafe impl Send for RetiredCursor {}

pub(crate) struct MediaReclaimer {
    sender: mpsc::Sender<Message>,
}

impl MediaReclaimer {
    fn start() -> std::io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        std::thread::Builder::new()
            .name("zic-media-release".into())
            .spawn(move || {
                while let Ok(message) = receiver.recv() {
                    match message {
                        Message::Release(frame) => drop(frame),
                        Message::Cursor(cursor) => drop(cursor.0),
                        Message::Source(source) => drop(source),
                        Message::Drain(done) => {
                            let _ = done.send(());
                        }
                        #[cfg(test)]
                        Message::Pause(started, resume) => {
                            started.send(()).unwrap();
                            resume.recv().unwrap();
                        }
                    }
                }
            })?;
        Ok(Self { sender })
    }

    pub(crate) fn release(&self, frame: Box<FrameHandle>) {
        if let Err(mpsc::SendError(Message::Release(frame))) =
            self.sender.send(Message::Release(frame))
        {
            // An unavailable worker must not leak the caller's last reference.
            drop(frame);
        }
    }

    pub(crate) fn drain(&self) -> bool {
        let (done, completed) = mpsc::sync_channel(0);
        self.sender.send(Message::Drain(done)).is_ok() && completed.recv().is_ok()
    }

    pub(crate) fn release_cursor(&self, cursor: Box<Cursor>) {
        if let Err(mpsc::SendError(Message::Cursor(cursor))) =
            self.sender.send(Message::Cursor(RetiredCursor(cursor)))
        {
            drop(cursor.0);
        }
    }

    pub(crate) fn release_source(&self, source: Box<ByteSource>) {
        if let Err(mpsc::SendError(Message::Source(source))) =
            self.sender.send(Message::Source(source))
        {
            drop(source);
        }
    }
}

pub(crate) fn reclaimer() -> Option<&'static MediaReclaimer> {
    static RECLAIMER: OnceLock<Option<MediaReclaimer>> = OnceLock::new();
    RECLAIMER
        .get_or_init(|| MediaReclaimer::start().ok())
        .as_ref()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn queued_release_preserves_other_handles_and_drain_drops_the_last_owner() {
        let reclaimer = MediaReclaimer::start().unwrap();
        let frame = Box::new(FrameHandle::test_frame(1, 2, vec![1; 4 * 1024 * 1024]));
        let weak = Arc::downgrade(&frame.data);
        let retained = Box::new(FrameHandle {
            data: Arc::clone(&frame.data),
        });
        reclaimer.release(frame);
        assert!(reclaimer.drain());
        assert_eq!(Arc::strong_count(&retained.data), 1);
        assert_eq!(retained.data.bytes[0], 1);
        reclaimer.release(retained);
        assert!(reclaimer.drain());
        assert!(weak.upgrade().is_none());
    }

    #[test]
    fn source_release_keeps_the_exact_cursor_alive_until_it_also_retires() {
        let reclaimer = MediaReclaimer::start().unwrap();
        let source = Box::new(ByteSource::new(7, 1024 * 1024));
        let weak = Arc::downgrade(&source.inner);
        let cursor = unsafe { crate::zic_cursor_create(&*source, 7, 2, 2) };
        assert!(!cursor.is_null());
        reclaimer.release_source(source);
        assert!(reclaimer.drain());
        assert!(weak.upgrade().is_some());
        let mut frame = std::ptr::null_mut();
        let status = unsafe { crate::zic_cursor_decode_next(cursor, 7, &mut frame) };
        assert_eq!(status, crate::CursorStatus::NeedMoreData as u32);
        assert!(frame.is_null());
        reclaimer.release_cursor(unsafe { Box::from_raw(cursor) });
        assert!(reclaimer.drain());
        assert!(weak.upgrade().is_none());
    }

    #[test]
    fn caller_relinquishes_without_waiting_for_the_raster_destructor() {
        let reclaimer = MediaReclaimer::start().unwrap();
        let (started, running) = mpsc::sync_channel(0);
        let (resume, paused) = mpsc::channel();
        reclaimer
            .sender
            .send(Message::Pause(started, paused))
            .unwrap();
        running.recv().unwrap();
        let frame = Box::new(FrameHandle::test_frame(1, 2, vec![1; 1024 * 1024]));
        let weak = Arc::downgrade(&frame.data);
        reclaimer.release(frame);
        // The worker is paused: freeing here would still block the UI caller.
        assert!(weak.upgrade().is_some());
        resume.send(()).unwrap();
        assert!(reclaimer.drain());
        assert!(weak.upgrade().is_none());
    }
}
