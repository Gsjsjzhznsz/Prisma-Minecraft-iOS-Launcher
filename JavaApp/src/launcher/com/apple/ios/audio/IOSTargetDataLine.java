package com.apple.ios.audio;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import javax.sound.sampled.*;

public class IOSTargetDataLine implements TargetDataLine {

    private AudioFormat format;
    private int bufferSize;
    private volatile boolean open, running;
    private long nativeHandle;
    private final Object lock = new Object();
    private final List<LineListener> listeners = new CopyOnWriteArrayList<>();

    @Override
    public void open() throws LineUnavailableException {
        throw new LineUnavailableException("Use open(AudioFormat) instead");
    }

    @Override
    public void open(AudioFormat format, int bufferSize) throws LineUnavailableException {
        // ame274：open 全程持锁——原先仅"状态检查"与"赋值"两小段持锁，
        // 并发 open 时两次 NativeAudioCapture.init 产生两个 native handle，
        // 后者覆盖前者 = 先者泄漏（无人 release）。Java 锁可重入，锁内
        // close() 的 stop/release 语义不变；fireEvent 仍在锁外，同现状。
        synchronized (lock) {
            if (open) close();
            if (format.getEncoding() != AudioFormat.Encoding.PCM_SIGNED
                    || format.getSampleSizeInBits() != 16
                    || format.getChannels() != 1) {
                throw new LineUnavailableException("Unsupported format: " + format);
            }
            this.format = format;
            this.bufferSize = Math.max(bufferSize, 4096);
            long handle = NativeAudioCapture.init(
                (int) format.getSampleRate(),
                format.getChannels(),
                format.getSampleSizeInBits(),
                format.isBigEndian()
            );
            if (handle == 0) {
                throw new LineUnavailableException("Failed to initialize native audio capture");
            }
            nativeHandle = handle;
            open = true;
        }
        fireEvent(LineEvent.Type.OPEN);
    }

    @Override
    public void open(AudioFormat format) throws LineUnavailableException {
        open(format, 4096);
    }

    @Override
    public void close() {
        long handle;
        synchronized (lock) {
            if (!open) return;
            if (running) {
                running = false;
                NativeAudioCapture.stop(nativeHandle);
            }
            open = false;
            handle = nativeHandle;
            nativeHandle = 0;
        }
        if (handle != 0) {
            // ★ Task268（scan-b #2）：read() 锁内取句柄/锁外用句柄，close 同步
            // release 与在途 native read 构成 UAF（native read 会阻塞等音频数据，
            // 不能持 Java 键）。stop() 已广播唤醒在途 read，宽限 500ms 后释放，
            // 覆盖其返回路径（守护线程，不阻塞关闭）。
            Thread ame268Releaser = new Thread(new Runnable() {
                public void run() {
                    try { Thread.sleep(500); } catch (InterruptedException ignored) {}
                    NativeAudioCapture.release(handle);
                }
            }, "Ame268-AudioCaptureRelease");
            ame268Releaser.setDaemon(true);
            ame268Releaser.start();
        }
        fireEvent(LineEvent.Type.CLOSE);
    }

    @Override
    public boolean isOpen() {
        return open;
    }

    @Override
    public void start() {
        long handle;
        synchronized (lock) {
            if (!open || running) return;
            running = true;
            handle = nativeHandle;
        }
        NativeAudioCapture.start(handle);
        fireEvent(LineEvent.Type.START);
    }

    @Override
    public void stop() {
        long handle;
        synchronized (lock) {
            if (!running) return;
            running = false;
            handle = nativeHandle;
        }
        NativeAudioCapture.stop(handle);
        fireEvent(LineEvent.Type.STOP);
    }

    @Override
    public boolean isRunning() {
        return running;
    }

    @Override
    public boolean isActive() {
        return running;
    }

    @Override
    public AudioFormat getFormat() {
        return format;
    }

    @Override
    public int getBufferSize() {
        return bufferSize;
    }

    @Override
    public int available() {
        long handle;
        synchronized (lock) {
            if (!open) return 0;
            handle = nativeHandle;
        }
        return NativeAudioCapture.available(handle);
    }

    @Override
    public int read(byte[] b, int off, int len) {
        long handle;
        synchronized (lock) {
            if (!open || !running) return -1;
            handle = nativeHandle;
        }
        if (handle == 0) return -1;
        int n = NativeAudioCapture.read(handle, b, off, len);
        return n < 0 ? -1 : n;
    }

    public int remaining() {
        return 0;
    }

    @Override
    public float getLevel() {
        return AudioSystem.NOT_SPECIFIED;
    }

    @Override
    public void drain() {
    }

    @Override
    public void flush() {
    }

    @Override
    public long getLongFramePosition() {
        return 0;
    }

    @Override
    public int getFramePosition() {
        return 0;
    }

    @Override
    public long getMicrosecondPosition() {
        return 0;
    }

    @Override
    public void addLineListener(LineListener listener) {
        if (!listeners.contains(listener)) listeners.add(listener);
    }

    @Override
    public void removeLineListener(LineListener listener) {
        listeners.remove(listener);
    }

    @Override
    public Control[] getControls() {
        return new Control[0];
    }

    @Override
    public boolean isControlSupported(Control.Type control) {
        return false;
    }

    @Override
    public Control getControl(Control.Type control) {
        throw new IllegalArgumentException("Unsupported control: " + control);
    }

    @Override
    public Line.Info getLineInfo() {
        return new DataLine.Info(TargetDataLine.class, format, bufferSize);
    }

    private void fireEvent(LineEvent.Type type) {
        LineEvent event = new LineEvent(this, type, getLongFramePosition());
        for (LineListener l : listeners) {
            l.update(event);
        }
    }
}
