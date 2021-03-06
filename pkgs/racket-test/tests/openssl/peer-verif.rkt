#lang racket

(require openssl
         ffi/unsafe
         racket/tcp
         racket/runtime-path)

(define (check fmt got expect)
  (unless (equal? got expect)
    (error 'check fmt got)))

(define-runtime-path server-key "server_key.pem")
(define-runtime-path server-crt "server_crt.pem")
(define-runtime-path client-key "client_key.pem")
(define-runtime-path client-crt "client_crt.pem")
(define-runtime-path cacert     "cacert.pem")

;; TLS v1.3 does not allow renegotiation, so use v1.2 for testing if
;; available, otherwise skip renegotiation
(define can-tls12? (memq 'tls12 (supported-client-protocols)))
(printf (if can-tls12?
            "Using TLS v1.2\n"
            "Skipping renegotiation tests\n"))

(define (go valid? 
            #:later [later-mode #f]
            #:early [early-mode (and (not later-mode) 'try)]
            #:accept-fail? [accept-fail? #f]
            #:verify-fail? [verify-fail? #f])
  (define ssl-server-context (ssl-make-server-context))

  (ssl-load-private-key! ssl-server-context server-key)
  (ssl-load-certificate-chain! ssl-server-context server-crt)
  (ssl-load-verify-root-certificates! ssl-server-context cacert)
  (when early-mode
    ((if (eq? early-mode 'try) ssl-try-verify! ssl-set-verify!)
     ssl-server-context 
     #t))

  (define ssl-listener (ssl-listen 0
                                   4
                                   #t
                                   "127.0.0.1"
                                   ssl-server-context))

  (define port-number (let ()
                        (define-values (addr port-number other-addr other-port-number)
                          (ssl-addresses ssl-listener #t))
                        port-number))

  (define listener-main 
    (thread 
     (lambda()
       (with-handlers ([(lambda (x) (and accept-fail?
                                         (exn? x)
                                         (regexp-match? #rx"accept failed" (exn-message x))))
                        (lambda (x) (ssl-close ssl-listener))]
                       [(lambda (x) (and verify-fail? (eq? x 'escape)))
                        (lambda (x) (void))]
                       [(lambda (x) (and (eq? later-mode 'req)
                                         (not valid?)
                                         verify-fail?
                                         (exn? x)
                                         ;; late checking may abandon the connection
                                         (regexp-match?
                                          #rx"(^tcp-(?:read|write):|error (reading from|writing to) stream port)"
                                          (exn-message x))))
                        (lambda (x) (void))])
         (let-values ([(in out) (ssl-accept ssl-listener)])
           (check "Server: Accepted connection.~n" #t #t)
           (when later-mode
             (check "Server: From Client: ~a~n" (read-line in) "we're started")
             (with-handlers ([(lambda (x) (and verify-fail?
                                               (exn? x)
                                               (regexp-match? #rx"ssl-set-verify!: failed" (exn-message x))))
                              (lambda (x) 
                                (ssl-close ssl-listener)
                                (raise 'escape))])
               ((if (eq? later-mode 'try) ssl-try-verify! ssl-set-verify!) in #t))
             (write-string "still going\n" out)
             (flush-output out))
           (check "Server: Verified ~v~n" (ssl-peer-verified? in) valid?)
           (check "Server: Verified ~v~n" (ssl-peer-verified? out) valid?)
           (check "Server: Verified Peer Subject Name ~v~n" (ssl-peer-subject-name in)
                  (and valid?
                       #"/C=US/ST=Racketa/O=Testing Examples/OU=Testing/CN=client.example.com/emailAddress=client@example.com"))
           (check "Server: Verified Peer Issuer Name ~v~n" (ssl-peer-issuer-name in)
                  (and valid?
                       #"/C=US/ST=Racketa/L=Racketville/O=Testing Examples/OU=Testing/CN=example.com/emailAddress=ca@example.com"))
           (ssl-close ssl-listener)
           (check "Server: From Client: ~a~n" (read-line in) "yay the connection was made")
           (close-input-port in)
           (close-output-port out))))))

  (define ssl-client-context (ssl-make-client-context (if can-tls12?
                                                          'tls12
                                                          'auto)))

  (ssl-load-private-key! ssl-client-context client-key)

  ;; connection will still proceed if these functions aren't called
  (when valid?
    (ssl-load-certificate-chain! ssl-client-context client-crt)
    (ssl-load-verify-root-certificates! ssl-client-context cacert)
    (ssl-set-verify! ssl-client-context #t))

  (let-values ([(in out) (ssl-connect "127.0.0.1"
                                      port-number
                                      ssl-client-context)])
    (check "Client: Made connection.~n" #t #t)
    (when later-mode
      (write-string "we're started\n" out)
      (flush-output out)
      (unless verify-fail?
        (check "Client: From Server: ~a~n" (read-line in) "still going")))
    (check "Client: Verified ~v~n" (ssl-peer-verified? in) valid?)
    (check "Client: Verified ~v~n" (ssl-peer-verified? out) valid?)
    (check "Client: Verified Peer Subject Name ~v~n" (ssl-peer-subject-name in)
           #"/C=US/ST=Racketa/O=Testing Examples/OU=Testing/CN=server.example.com/emailAddress=server@example.com")
    (check "Client: Verified Peer Issuer Name ~v~n" (ssl-peer-issuer-name in)
           #"/C=US/ST=Racketa/L=Racketville/O=Testing Examples/OU=Testing/CN=example.com/emailAddress=ca@example.com")
    
    (write-string (format "yay the connection was made~n") out)
    (close-input-port in)
    (close-output-port out))

  (thread-wait listener-main))

(go #t)
(go #t #:early 'req)
(go #f)
(when can-tls12?
  (go #t #:later 'try))
(go #f #:later 'try)
(when can-tls12?
  (go #t #:later 'req))

(define (check-fail thunk)
  (define s
    (with-handlers ([exn? (lambda (exn) (exn-message exn))])
      (thunk)
      "success"))
  (unless (regexp-match?  #rx"connect failed" s)
    (error 'test "failed: ~s" s)))

(check-fail (lambda () (go #f #:early 'req #:accept-fail? #t)));
(go #f #:later 'req #:verify-fail? #t)

