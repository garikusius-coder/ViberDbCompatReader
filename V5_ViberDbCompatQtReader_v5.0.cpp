// Viber AI Manager v5.0 CLEAN
// Module: V5_ViberDbCompatQtReader
// Version: 5.0.2-prototype
// Task: V5-040 Fix 7
// Mode: PROBE_ONLY_ISOLATED_READ_ONLY_CODEC_READER
//
// Input: one JSON object on stdin. Paths and optional key material never appear in argv.
// Output: privacy-safe JSON only; never echoes key, DB/plugin paths, SQL error text, phone, ChatID or EventID.
//
// Safety:
// - KEYLESS_PROBE is the Fix 7 path and uses no key material.
// - Legacy PROBE remains available only for a future explicitly approved in-memory key source; Fix 7 launcher never calls it.
// - QSQLITE_OPEN_READONLY + bounded busy timeout + PRAGMA query_only=ON.
// - No INSERT/UPDATE/DELETE/DDL/ATTACH/VACUUM/rekey/history/send/network/file output/AUTO/DIRECT_CHAT.

#include <QCoreApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTextStream>

static QJsonObject baseResult(const QString &result)
{
    QJsonObject o;
    o["result"] = result;
    o["schemaReadable"] = false;
    o["requiredTableCount"] = 0;
    o["dbWriteAttempted"] = false;
    o["directChatInvoked"] = false;
    o["plaintextDumpCreated"] = false;
    o["sendInvoked"] = false;
    o["keyLogged"] = false;
    o["keyPersisted"] = false;
    o["keyMaterialUsed"] = false;
    return o;
}

static QJsonObject fail(const QString &code)
{
    QJsonObject o = baseResult("FAIL");
    o["errorCode"] = code;
    return o;
}

static bool execControlPragma(QSqlDatabase &db, const QString &sql)
{
    QSqlQuery q(db);
    return q.exec(sql);
}

static bool readSchemaSignature(QSqlDatabase &db, int &requiredCount)
{
    QSqlQuery q(db);
    const QString schemaSql =
        "SELECT COUNT(DISTINCT name) FROM sqlite_master "
        "WHERE type='table' AND name IN ('Contact','ChatInfo','ChatRelation','Events','Messages');";
    if (!q.exec(schemaSql) || !q.next()) return false;
    requiredCount = q.value(0).toInt();
    return true;
}

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream in(stdin);
    QTextStream out(stdout);

    QByteArray input = in.readLine().toUtf8();
    QJsonParseError parseError;
    QJsonDocument doc = QJsonDocument::fromJson(input, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
        input.fill('\0');
        out << QJsonDocument(fail("INVALID_INPUT")).toJson(QJsonDocument::Compact) << Qt::endl;
        return 2;
    }

    QJsonObject req = doc.object();
    const QString mode = req.value("mode").toString();
    const QString dbPath = req.value("dbPath").toString();
    const QString pluginRoot = req.value("pluginRoot").toString();
    QString hexkey = req.value("hexkey").toString();

    req.remove("hexkey");
    doc = QJsonDocument();
    input.fill('\0');
    input.clear();

    const bool keylessMode = (mode == "KEYLESS_PROBE");
    const bool keyedMode = (mode == "PROBE");
    if (!keylessMode && !keyedMode) {
        hexkey.fill(QChar('0')); hexkey.clear();
        out << QJsonDocument(fail("MODE_NOT_ALLOWED")).toJson(QJsonDocument::Compact) << Qt::endl;
        return 2;
    }
    if (dbPath.isEmpty() || pluginRoot.isEmpty()) {
        hexkey.fill(QChar('0')); hexkey.clear();
        out << QJsonDocument(fail("PATH_INPUT_MISSING")).toJson(QJsonDocument::Compact) << Qt::endl;
        return 2;
    }
    if (keylessMode && !hexkey.isEmpty()) {
        hexkey.fill(QChar('0')); hexkey.clear();
        out << QJsonDocument(fail("KEY_MATERIAL_NOT_ALLOWED_IN_KEYLESS_MODE")).toJson(QJsonDocument::Compact) << Qt::endl;
        return 2;
    }
    if (keyedMode && !QRegularExpression("^[0-9A-Fa-f]{64}$").match(hexkey).hasMatch()) {
        hexkey.fill(QChar('0')); hexkey.clear();
        out << QJsonDocument(fail("HEXKEY_INVALID_OR_MISSING")).toJson(QJsonDocument::Compact) << Qt::endl;
        return 2;
    }

    QCoreApplication::addLibraryPath(pluginRoot);
    if (!QSqlDatabase::isDriverAvailable("QSQLITE")) {
        hexkey.fill(QChar('0')); hexkey.clear();
        out << QJsonDocument(fail("QSQLITE_DRIVER_UNAVAILABLE")).toJson(QJsonDocument::Compact) << Qt::endl;
        return 3;
    }

    const QString connectionName = "v5_viber_codec_probe";
    int exitCode = 0;
    QJsonObject response;

    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", connectionName);
        db.setConnectOptions("QSQLITE_OPEN_READONLY;QSQLITE_BUSY_TIMEOUT=1000");
        db.setDatabaseName(dbPath);

        if (!db.open()) {
            response = fail("DB_OPEN_FAILED");
            exitCode = 4;
        } else if (!execControlPragma(db, "PRAGMA query_only=ON;")) {
            response = fail("QUERY_ONLY_PRAGMA_FAILED");
            exitCode = 5;
        } else {
            bool keyAccepted = true;
            if (keyedMode) {
                QString pragma = "PRAGMA hexkey='" + hexkey + "';";
                keyAccepted = execControlPragma(db, pragma);
                pragma.fill(QChar('0')); pragma.clear();
                hexkey.fill(QChar('0')); hexkey.clear();
            }

            if (!keyAccepted) {
                response = fail("HEXKEY_PRAGMA_REJECTED");
                exitCode = 5;
            } else {
                int requiredCount = 0;
                if (!readSchemaSignature(db, requiredCount)) {
                    response = fail(keylessMode ? "KEYLESS_SCHEMA_NOT_READABLE" : "CODEC_OR_KEY_NOT_VALIDATED");
                    exitCode = 6;
                } else if (requiredCount != 5) {
                    response = fail("SCHEMA_SIGNATURE_MISMATCH");
                    response["requiredTableCount"] = requiredCount;
                    exitCode = 6;
                } else {
                    response = baseResult(keylessMode ? "KEYLESS_CODEC_READ_PASS" : "CODEC_READ_PASS");
                    response["schemaReadable"] = true;
                    response["requiredTableCount"] = 5;
                    response["driver"] = "QSQLITE";
                    response["keyMaterialUsed"] = keyedMode;
                }
            }
            db.close();
        }
    }

    hexkey.fill(QChar('0')); hexkey.clear();
    QSqlDatabase::removeDatabase(connectionName);
    out << QJsonDocument(response).toJson(QJsonDocument::Compact) << Qt::endl;
    return exitCode;
}
