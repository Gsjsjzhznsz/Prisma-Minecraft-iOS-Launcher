package com.github.caciocavallosilano.cacio.ctc;

import java.awt.Desktop;
import java.awt.desktop.AboutHandler;
import java.awt.desktop.QuitHandler;
import java.awt.peer.DesktopPeer;
import java.io.File;
import java.io.IOException;
import java.net.URI;

/**
 * Task226 (feedback #9: open-folder no-op on Java 17/21/25 + NoSuchMethodError
 * crash): the stock cacio-tta 1.18 CTCDesktopPeer is a pure STUB -- every
 * action method throws IOException("Action not supported"), which surfaces in
 * Minecraft as "Failed to open uri file:///...: No handler registered for this
 * type of URL" and the in-game "open folder" button does nothing. Worse, the
 * previous Task225 native fix tried RegisterNatives("openFile","(Ljava/lang/String;)V")
 * against this stub -- the method does not exist there, RegisterNatives raised
 * a pending NoSuchMethodError and the Render thread died with it.
 *
 * This replacement mirrors the Java 8 (cacio-androidnw 1.10) bridge shape that
 * has always worked on device: two STATIC NATIVE entry points
 *   openFile(String) / openUri(String)
 * which the launcher's input_bridge registers (same JNI signatures as the
 * Java 8 class), plus full DesktopPeer implementations that funnel every
 * action into those bridges:
 *   open/edit/print(File) -> openFile(file.getAbsolutePath())
 *   mail/browse(URI)      -> openUri(uri.toString())
 * isSupported() reports OPEN/BROWSE/EDIT/PRINT/MAIL as supported so
 * java.awt.Desktop actually routes calls here instead of failing upfront.
 */
public class CTCDesktopPeer implements DesktopPeer {

    /** Launcher JNI bridge (input_bridge_v3.m, registered per JVM session). */
    public static native void openFile(String path) throws IOException;

    /** Launcher JNI bridge (same registration; URI form for browse/mail). */
    public static native void openUri(String uri) throws IOException;

    public CTCDesktopPeer() {
    }

    @Override
    public boolean isSupported(Desktop.Action action) {
        if (action == null) {
            return false;
        }
        switch (action) {
            case OPEN:
            case BROWSE:
            case EDIT:
            case PRINT:
            case MAIL:
                return true;
            default:
                return false;
        }
    }

    @Override
    public void setAboutHandler(AboutHandler aboutHandler) {
        // Not applicable on the launcher surface; accepted silently.
    }

    @Override
    public void setQuitHandler(QuitHandler quitHandler) {
        // Not applicable on the launcher surface; accepted silently.
    }

    @Override
    public void open(File file) throws IOException {
        openFile(file == null ? null : file.getAbsolutePath());
    }

    @Override
    public void edit(File file) throws IOException {
        openFile(file == null ? null : file.getAbsolutePath());
    }

    @Override
    public void print(File file) throws IOException {
        openFile(file == null ? null : file.getAbsolutePath());
    }

    @Override
    public void mail(URI uri) throws IOException {
        openUri(uri == null ? null : uri.toString());
    }

    @Override
    public void browse(URI uri) throws IOException {
        openUri(uri == null ? null : uri.toString());
    }
}
