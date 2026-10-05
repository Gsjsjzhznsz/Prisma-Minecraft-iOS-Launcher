package net.kdt.pojavlaunch.value;
import net.kdt.pojavlaunch.*;
import java.io.*;
import com.google.gson.*;

public class MinecraftAccount
{
    public String accessToken = "0"; // access token
    public String clientToken = "0"; // clientID: refresh and invalidate
    public String profileId = "00000000-0000-0000-0000-000000000000"; // authenticate UUID
    public String username = "Steve";
    public String xuid;
    // Task220：显式账户类型标记（"microsoft"/"thirdparty"/"local"，由原生端
    // 登录流程写入 .json）。旧版文件无此键（null）→ Tools 侧回退键位嗅探。
    // 病历：混合文件（xuid 与 clientToken 并存）在旧嗅探下被误判为微软，
    // authlib-injector 会话打出 "Setting accountType to msa" 的串类证据。
    public String accountType;
    // 账户唯一标识：微软账户=xuid，第三方账户=profileId，本地账户=UUID
    // 与原生端 BaseAuthenticator.authData[@"accountId"] 一致，用作账户文件名
    public String accountId = "";

    public String save(String outPath) throws IOException {
        Tools.write(outPath, Tools.GLOBAL_GSON.toJson(this));
        return outPath;
    }

    public String save() throws IOException {
        // 文件名使用 accountId（唯一标识），同名账户不再冲突
        String id = (accountId != null && !accountId.isEmpty()) ? accountId : username;
        return save(Tools.DIR_ACCOUNT_NEW + "/" + id + ".json");
    }

    public static MinecraftAccount parse(String content) throws JsonSyntaxException {
        MinecraftAccount account = Tools.GLOBAL_GSON.fromJson(content, MinecraftAccount.class);
        // Read access token from keychain
        if (account.xuid != null) {
            account.accessToken = getAccessTokenFromKeychain(account.xuid);
        }
        return account;
    }

    public static MinecraftAccount load(String name) throws IOException, JsonSyntaxException {
        // name 即 accountId（由原生端 launchJVM 的 args[0] 传入），用作账户文件名
        MinecraftAccount acc = parse(Tools.read(Tools.DIR_ACCOUNT_NEW + "/" + name + ".json"));
        if (acc.accessToken == null) {
            acc.accessToken = "0";
        } if (acc.clientToken == null) {
            acc.clientToken = "0";
        } if (acc.profileId == null) {
            acc.profileId = "0";
        } if (acc.username == null) {
            acc.username = "0";
        } if (acc.xuid == null) {
            acc.xuid = "0";
        } if (acc.accountType == null) {
            acc.accountType = "";
        }
        // 兜底 accountId：优先用入参 name（原生端传入的 accountId），其次 xuid，最后 profileId
        if (acc.accountId == null || acc.accountId.isEmpty()) {
            acc.accountId = name;
        }
        return acc;
    }

    static {
        System.loadLibrary("AmethystAccountJNI");
    }
    public static native String getAccessTokenFromKeychain(String xuid);
}
