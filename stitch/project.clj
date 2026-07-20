;; Minimal Leiningen project used ONLY to publish the prebuilt, security-patched
;; MySQL Connector/J jar to our private maven repo. It does not build any source
;; itself — stitch/deploy-jar.sh calls `lein deploy` with explicit coordinates
;; and points it at the jar/pom produced by stitch/build-jar.sh.
;;
;; s3-wagon-private + :no-auth true means it uses ambient AWS SSO credentials,
;; matching how our services (loader-mysql, connections-service, ...) resolve
;; and publish artifacts.
(defproject com.mysql/mysql-connector-j "8.0.33-stitch-2"
  :description "Stitch security-patched fork of MySQL Connector/J (rogue-MySQL LOCAL INFILE fix). Deploy helper only."
  :plugins [[s3-wagon-private "1.3.5"]]
  :repositories [["releases"  {:url           "s3p://com-stitchdata-prod-maven-repository/releases"
                               :no-auth       true
                               :sign-releases false}]
                 ["snapshots" {:url           "s3p://com-stitchdata-prod-maven-repository/snapshots"
                               :no-auth       true
                               :sign-releases false}]])
