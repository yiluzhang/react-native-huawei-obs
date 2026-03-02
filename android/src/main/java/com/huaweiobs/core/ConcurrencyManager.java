package com.huaweiobs.core;

import android.util.Log;

import java.util.concurrent.Semaphore;

/**
 * 并发管理器
 * 负责计算和控制全局并发上限，防止内存溢出
 */
public class ConcurrencyManager {
    private static final String TAG = "ConcurrencyManager";
    private static final int MIN_CONCURRENCY = 1;
    private static final int MAX_CONCURRENCY = 10;

    private final int configMaxConcurrency;
    private int currentConcurrency;
    private Semaphore semaphore;

    public ConcurrencyManager(int configMaxConcurrency) {
        this.configMaxConcurrency = configMaxConcurrency;
        this.currentConcurrency = configMaxConcurrency;
        this.semaphore = new Semaphore(currentConcurrency);
    }

    /**
     * 计算实际并发上限
     * 基于系统可用内存和分片大小
     */
    public int calculateConcurrency(int partSizeMB, int configConcurrency) {
        long availableMemoryMB = getAvailableMemoryMB();

        // 计算最大并发数：可用内存 / 分片大小
        int maxInFlight = partSizeMB > 0 ? (int) (availableMemoryMB / partSizeMB) : configConcurrency;

        // 取最小值，并限制在合理范围内
        int actualConcurrency = Math.min(configConcurrency, maxInFlight);
        int boundedConcurrency = Math.max(MIN_CONCURRENCY, Math.min(MAX_CONCURRENCY, actualConcurrency));

        Log.d(TAG, String.format(
            "Calculated concurrency: %d (available memory: %dMB, part size: %dMB, config: %d)",
            boundedConcurrency, availableMemoryMB, partSizeMB, configConcurrency
        ));

        // 如果并发数变化，更新 semaphore
        if (boundedConcurrency != currentConcurrency) {
            updateConcurrency(boundedConcurrency);
        }

        return boundedConcurrency;
    }

    /**
     * 获取系统可用内存（MB）
     */
    public long getAvailableMemoryMB() {
        Runtime runtime = Runtime.getRuntime();
        long maxMemory = runtime.maxMemory() / (1024 * 1024);
        long totalMemory = runtime.totalMemory() / (1024 * 1024);
        long freeMemory = runtime.freeMemory() / (1024 * 1024);
        return maxMemory - (totalMemory - freeMemory);
    }

    /**
     * 获取系统总内存（MB）
     */
    public long getTotalMemoryMB() {
        return Runtime.getRuntime().maxMemory() / (1024 * 1024);
    }

    /**
     * 获取当前并发数
     */
    public int getCurrentConcurrency() {
        return currentConcurrency;
    }

    /**
     * 获取 Semaphore
     */
    public Semaphore getSemaphore() {
        return semaphore;
    }

    /**
     * 更新并发数
     */
    private synchronized void updateConcurrency(int newConcurrency) {
        if (newConcurrency == currentConcurrency) {
            return;
        }

        Log.d(TAG, "Updating concurrency from " + currentConcurrency + " to " + newConcurrency);
        
        int diff = newConcurrency - currentConcurrency;
        if (diff > 0) {
            // 增加许可
            semaphore.release(diff);
        } else {
            // 减少许可（尝试获取多余的许可）
            semaphore.acquireUninterruptibly(-diff);
        }

        currentConcurrency = newConcurrency;
    }

    /**
     * 在并发限制下执行任务
     */
    public <T> T executeWithLimit(Task<T> task) throws Exception {
        semaphore.acquire();
        try {
            return task.execute();
        } finally {
            semaphore.release();
        }
    }

    /**
     * 任务接口
     */
    public interface Task<T> {
        T execute() throws Exception;
    }
}
