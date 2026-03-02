package com.huaweiobs.core;

import android.util.Log;

import com.obs.services.ObsClient;
import com.obs.services.ObsConfiguration;
import com.huaweiobs.utils.OBSException;

import java.util.HashMap;
import java.util.Map;

/**
 * OBS 客户端持有者
 * 封装华为云官方 ObsClient，管理配置和生命周期
 */
public class ObsClientHolder {
    private static final String TAG = "ObsClientHolder";
    private ObsClient obsClient;
    private Map<String, Object> currentConfig;

    /**
     * 创建 OBS 客户端
     */
    public synchronized void createClient(Map<String, Object> config) throws OBSException {
        closeClient();

        try {
            String endpoint = (String) config.get("endpoint");
            if (endpoint == null) {
                throw new IllegalArgumentException("Missing endpoint");
            }
            // setEndPoint 只接受主机名，去掉 http:// / https:// 前缀
            endpoint = endpoint.replaceFirst("^https?://", "");

            Log.i(TAG, "[Init] endpoint=" + endpoint
                    + "  bucket=" + config.get("bucket")
                    + "  socketTimeout=" + config.get("socketTimeout")
                    + "  connectionTimeout=" + config.get("connectionTimeout")
                    + "  maxRetry=" + config.get("maxErrorRetry"));

            String accessKeyId = (String) config.get("accessKeyId");
            if (accessKeyId == null) {
                throw new IllegalArgumentException("Missing accessKeyId");
            }

            String secretAccessKey = (String) config.get("secretAccessKey");
            if (secretAccessKey == null) {
                throw new IllegalArgumentException("Missing secretAccessKey");
            }

            ObsConfiguration obsConfiguration = new ObsConfiguration();
            obsConfiguration.setEndPoint(endpoint);
            
            Boolean isHttps = (Boolean) config.get("isHttps");
            obsConfiguration.setHttpsOnly(isHttps != null ? isHttps : true);
            
            // RN bridge 传来的数字类型为 Double，需通过 Number 中转再取 int
            Number socketTimeoutNum = (Number) config.get("socketTimeout");
            obsConfiguration.setSocketTimeout(socketTimeoutNum != null ? socketTimeoutNum.intValue() : 60000);
            
            Number connectionTimeoutNum = (Number) config.get("connectionTimeout");
            obsConfiguration.setConnectionTimeout(connectionTimeoutNum != null ? connectionTimeoutNum.intValue() : 60000);
            
            Number maxErrorRetryNum = (Number) config.get("maxErrorRetry");
            obsConfiguration.setMaxErrorRetry(maxErrorRetryNum != null ? maxErrorRetryNum.intValue() : 3);
            
            Boolean pathStyle = (Boolean) config.get("pathStyle");
            obsConfiguration.setPathStyle(pathStyle != null ? pathStyle : false);

            // 创建客户端
            // 注意：空字符串与 null 同等对待，避免用空 token 初始化导致认证失败
            String securityToken = (String) config.get("securityToken");
            if (securityToken != null && !securityToken.isEmpty()) {
                // STS 临时凭证（临时 AK/SK + Security Token）
                Log.i(TAG, "[Init] credential=STS  AK_prefix=" + accessKeyId.substring(0, Math.min(6, accessKeyId.length())));
                obsClient = new ObsClient(accessKeyId, secretAccessKey, securityToken, obsConfiguration);
            } else {
                // 永久 AK/SK
                Log.i(TAG, "[Init] credential=PERMANENT  AK_prefix=" + accessKeyId.substring(0, Math.min(6, accessKeyId.length())));
                obsClient = new ObsClient(accessKeyId, secretAccessKey, obsConfiguration);
            }

            currentConfig = new HashMap<>(config);
            Log.i(TAG, "[Init] OBS client created successfully");
        } catch (Exception e) {
            Log.e(TAG, "[Init] Failed to create OBS client: " + e.getMessage(), e);
            throw new OBSException("E_INIT_FAILED", "Failed to create OBS client: " + e.getMessage(), e);
        }
    }

    /**
     * 更新配置
     */
    public synchronized void updateConfig(Map<String, Object> newConfig) throws OBSException {
        Map<String, Object> mergedConfig = new HashMap<>();
        if (currentConfig != null) {
            mergedConfig.putAll(currentConfig);
        }
        mergedConfig.putAll(newConfig);
        createClient(mergedConfig);
    }

    /**
     * 获取客户端实例
     */
    public synchronized ObsClient getClient() throws OBSException {
        if (obsClient == null) {
            throw new OBSException("E_UNKNOWN", "OBS client not initialized", null);
        }
        return obsClient;
    }

    /**
     * 检查凭证是否过期
     */
    public boolean isCredentialsExpired() {
        if (currentConfig == null) {
            return false;
        }
        Number expiryTime = (Number) currentConfig.get("tokenExpiryTime");
        if (expiryTime == null) {
            return false;
        }
        return System.currentTimeMillis() > expiryTime.longValue();
    }

    /**
     * 获取当前配置
     */
    public Map<String, Object> getConfig() {
        return currentConfig != null ? new HashMap<>(currentConfig) : new HashMap<>();
    }

    /**
     * 关闭客户端
     */
    public synchronized void closeClient() {
        if (obsClient != null) {
            Log.i(TAG, "[Close] Closing OBS client");
        }
        try {
            if (obsClient != null) {
                obsClient.close();
            }
        } catch (Exception e) {
            Log.w(TAG, "[Close] Error while closing OBS client: " + e.getMessage());
        } finally {
            obsClient = null;
        }
    }
}
