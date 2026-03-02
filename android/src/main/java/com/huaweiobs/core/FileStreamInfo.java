package com.huaweiobs.core;

/**
 * 文件流信息
 */
public class FileStreamInfo {
    public final String streamId;
    public final long fileSize;
    public final String fileName;
    public final String mimeType;
    public final long lastModified;
    /** 经规范化后的本地绝对路径（content:// URI 已复制为临时文件） */
    public final String resolvedPath;

    public FileStreamInfo(String streamId, long fileSize, String fileName, String mimeType, long lastModified, String resolvedPath) {
        this.streamId = streamId;
        this.fileSize = fileSize;
        this.fileName = fileName;
        this.mimeType = mimeType;
        this.lastModified = lastModified;
        this.resolvedPath = resolvedPath;
    }
}
