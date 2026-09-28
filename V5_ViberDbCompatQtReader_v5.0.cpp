// Viber AI Manager v5.0 CLEAN
// Module: V5_ViberDbCompatQtReader
// Version: 5.0.1-prototype
// Task: V5-040 Fix 1
// Mode: PROBE_ONLY_ISOLATED_READ_ONLY_CODEC_READER
//
// Static prototype only. CHAT2 does not compile/run it against live Viber.
// Input: one JSON object on stdin. Key/db/plugin paths never appear in argv.
// Output: privacy-safe JSON only; never echoes key, db path, plugin path, SQL error text, phone, ChatID or EventID.
//
// Safety:
// - Only PROBE mode is accepted in Fix 1. DIRECT_CHAT is intentionally unavailable until CHAT1 confirms CODEC_READ_PASS.
// - QSQLITE_OPEN_READONLY + bounded busy timeout + PRAGMA query_only=ON.
// - Runtime PRAGMA hexkey is supplied from stdin memory only.
// - No INSERT/UPDATE/DELETE/DDL/ATTACH/VACUUM/rekey/history/send/network/file output/AUTO.

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

    if (mode != "PROBE") {
        hexkey.fill(QChar('0')); hexkey.clear();
        out << QJsonDocument(fail("MODE_NOT_ALLOWED")).toJson(QJsonDocument::Compact) << Qt::endl;
        return 2;
    }
    if (dbPath.isEmpty() || pluginRoot.isEmpty()) {
        hexkey.fill(QChar('0')); hexkey.clear();
        out << QJsonDocument(fail("PATH_INPUT_MISSING")).toJson(QJsonDocument::Compact) << Qt::endl;
        return 2;
    }
    if (!QRegularExpression("^[0-9A-Fa-f]{64}$").match(hexkey).hasMatch()) {
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
        } else {
            QString pragma = "PRAGMA hexkey='" + hexkey + "';";
            const bool keyAccepted = execControlPragma(db, pragma);
            pragma.fill(QChar('0')); pragma.clear();
            hexkey.fill(QChar('0')); hexkey.clear();

            if (!keyAccepted) {
                response = fail("HEXKEY_PRAGMA_REJECTED");
                exitCode = 5;
            } else if (!execControlPragma(db, "PRAGMA query_only=ON;")) {
                response = fail("QUERY_ONLY_PRAGMA_FAILED");
                exitCode = 5;
            } else {
                QSqlQuery q(db);
                const QString schemaSql =
                    "SELECT COUNT(DISTINCT name) FROM sqlite_master "
                    "WHERE type='table' AND name IN ('Contact','ChatInfo','ChatRelation','Events','Messages');";
                if (!q.exec(schemaSql) || !q.next()) {
                    response = fail("CODEC_OR_KEY_NOT_VALIDATED");
                    exitCode = 6;
                } else {
                    const int requiredCount = q.value(0).toInt();
                    if (requiredCount != 5) {
                        response = fail("SCHEMA_SIGNATURE_MISMATCH");
                        response["requiredTableCount"] = requiredCount;
                        exitCode = 6;
                    } else {
                        response = baseResult("CODEC_READ_PASS");
                        response["schemaReadable"] = true;
                        response["requiredTableCount"] = 5;
                        response["driver"] = "QSQLITE";
                    }
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
