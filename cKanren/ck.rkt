#lang racket

(require racket/generic 
         racket/stxparam
         "src/errors.rkt"
         (only-in rackunit check-equal?))

(require (for-syntax 
          syntax/parse
          racket/syntax
          "src/errors.rkt"))

(provide
 var? define-var-type goal? make-a c->list empty-s empty-c
 update-s update-c any/var?  prefix-s prtm identitym composem
 goal-construct ext-c build-oc oc-proc oc-rands oc-rator run run* prt
 extend-enforce-fns extend-reify-fns goal? a?  walk walk*
 mzerog unitg onceo fresh-aux conde conda condu ifa ifu project fresh
 succeed fail inc enforce-constraints reify empty-a take mzerom bindm
 format-source reify-cvar var ext-s gen:mk-struct recur constructor
 mk-struct?  lex<= sort-by-lex<= reify-with-colon default-mk-struct?
 occurs-check run-relevant-constraints build-attr-oc attr-oc?  attr-oc-uw?
 get-attributes filter/rator filter-not/rator default-reify attr-oc-type
 filter-memq/rator define-lazy-goal replace-ocs same-default-type?
 override-occurs-check? mk-struct->sexp var-x update-c-nocheck
 filter-not-memq/rator #%app-safe use-constraints debug replace-s
 update-s-nocheck update-s-prefix update-c-prefix attr-tag update-package
 default-reify-attr : define-constraint-interaction run-constraints)

(provide
 (rename-out 
  [lambdam@-external lambdam@]
  [lambdag@-external lambdag@]
  [trace-define-mk   trace-define]))

(provide 
 (for-syntax search-strategy))

;; parses the input to a write-proc
(define (parse-mode mode)
  (case mode [(#t) display] [(#f) display] [else display]))

(define attr-tag 'attr)

(define-syntax : (syntax-rules ()))

;; == VARIABLES =================================================================

;; normal miniKanren vars are actually an instance of a more general
;; "constrained var", or cvar for short.
(define-generics cvar (cvar->str cvar))

;; defines a normal miniKanren var as a cvar that is printed with "_"
(struct var (x) 
  #:methods gen:cvar 
  [(define (cvar->str x) "_")]
  #:methods gen:custom-write 
  [(define (write-proc . args) (apply write-var args))])

(define-syntax-rule (define-var-type name str rest ...)
  (struct name var () rest ...
    #:methods gen:cvar
    [(define (cvar->str x) str)]
    #:methods gen:custom-write
    [(define (write-proc . args) (apply write-var args))]))

;; write-var controls how variables are displayed
(define (write-var var port mode)
  ((parse-mode mode) (format "#~a(~s)" (cvar->str var) (var-x var)) port))

;; == GOALS ====================================================================

;; a goal is just a function that can be applied to a's
(struct goal (fn) 
  #:property prop:procedure (struct-field-index fn)
  #:methods gen:custom-write 
  ([define (write-proc goal port mode)
     ((parse-mode mode) "#<goal>" port)]))

;; macro to return a goal with the specified function
(define-syntax lambdag@-external
  (syntax-rules (:)
    [(_ (a) e ...) 
     (goal (lambda (a) e ...))]
    [(_ (a : s) e ...)
     (lambdag@ (a) 
       (let ([s (substitution-s (a-s a))])
         e ...))]
    [(_ (a : s c) e ...)
     (lambdag@ (a) 
       (let ([s (substitution-s (a-s a))]
             [c (constraint-store-c (a-c a))])
         e ...))]))

;; internal macro that can also divide the package into the queue and the tree
(define-syntax lambdag@
  (syntax-rules (:)
    [(_ (a) e ...)
     (goal (lambda (a) e ...))]
    [(_ (a : s c q t) e ...)
     (lambdag@ (a)
       (let ([s (a-s a)]
             [c (a-c a)]
             [q (a-q a)] 
             [t (a-t a)])
         e ...))]))

;; the failure value
(define (mzerog) #f)

;; the identity goal
(define unitg (lambdag@ (a) a))

;; succeed and fail are the simplest succeeding and failing goals
(define succeed unitg)
(define fail    (lambdag@ (a) (mzerog)))

;; for debugging, a goal that prints the substitution and a goal
;; that prints a message.  both succeed.

(define prt  
  (lambdag@ (a) (begin (printf "~a\n" a) a)))
(define (prtm . m) 
  (lambdag@ (a) (begin (apply printf m) a)))

(define (prtt . m) 
  (lambdag@ (a : s c q t) 
    (begin (display t) (display " ") (apply printf m) a)))

;; =============================================================================

;; macro that delays expressions
(define-syntax lambdaf@
  (syntax-rules ()
    ((_ () e) (lambda () e))))

;; delays an expression
(define-syntax inc 
  (syntax-rules ()
    ((_ e) (lambdaf@ () e))))

;; =============================================================================

;; convenience macro for dispatching on the type of a-inf
(define-syntax case-inf
  (syntax-rules ()
    ((_ e (() e0) ((f^) e1) ((a^) e2) ((a f) e3))
     (let ((a-inf e))
       (cond
         ((not a-inf) e0)
         ((procedure? a-inf)  (let ((f^ a-inf)) e1))
         ((not (and (pair? a-inf)
                    (procedure? (cdr a-inf))))
          (let ((a^ a-inf)) e2))
         (else (let ((a (car a-inf)) (f (cdr a-inf))) 
                 e3)))))))

(define empty-f (lambdaf@ () (mzerog)))
(define choiceg cons)

;; given a number n and a thunk containing an infinite stream f, takes
;; n answers from f
(define (take n f)
  (cond
    ((and n (zero? n)) '())
    (else
     (case-inf (f)
       (() '())
       ((f) (take n f))
       ((a) (cons a '()))
       ((a f) (cons a (take (and n (- n 1)) f)))))))

;; =============================================================================

;; defines a macro to create new unconstrained variables
(define-syntax-rule 
  (fresh-aux constructor (x ...) g g* ...)
  (lambdag@ (a) 
    (inc 
     (let ((x (constructor 'x)) ...) 
       (bindg* (app-goal g a) g* ...)))))

;; miniKanren's "fresh" defined in terms of fresh-aux over var
(define-syntax-rule (fresh (x ...) g g* ...)
  (fresh-aux var (x ...) g g* ...))

;; performs a conjunction over goals
(define-syntax bindg*
  (syntax-rules ()
    [(_ e) e]
    [(_ e g g* ...)
     (bindg* (bindg e g) g* ...)]))

;; applies a goal to an a-inf
(define bindg
  (lambda (a-inf g)
    (case-inf a-inf
      (() (mzerog))
      ((f) (inc (bindg (f) g)))
      ((a) (app-goal g a))
      ((a f) (mplusg (app-goal g a) (lambdaf@ () (bindg (f) g)))))))

(define-syntax mplusg*
  (syntax-rules ()
    ((_ e) e)
    ((_ e0 e ...)
     (mplusg e0 (lambdaf@ () (mplusg* e ...))))))

(define mplusg
  (lambda (a-inf f)
    (case-inf a-inf
      (() (f))
      ((f^) (inc (mplusg (f) f^)))
      ((a) (choiceg a f))
      ((a f^) (choiceg a (lambdaf@ () (mplusg (f) f^)))))))

(begin-for-syntax
 (define expand-debug? (make-parameter #f)))

(define-syntax-parameter conde
  (lambda (stx)
    (syntax-parse stx
      [(_ ((~optional (~seq #:name branch-name)) g g* ...) ...+)
       (cond
         [(expand-debug?)
          (with-syntax ([(branches ...) (attribute branch-name)])
            #'(debug-conde [#:name branches g g* ...] ...))]
         [else 
          #'(lambdag@ (a) 
              (inc 
               (mplusg* (bindg* (app-goal g a) g* ...) ...)))])])))

(define-syntax (debug-conde stx)
  (syntax-parse stx
    [(_ ((~optional (~seq #:name branch-name)) g g* ...) ...+)
     (with-syntax ([(labels ...) (attribute branch-name)])
       #'(lambdag@ (a : s c q t) 
           (inc 
            (mplusg* 
             (let ([a (make-a s c q (add-level t 'labels))])
               (bindg* (app-goal g a) g* ...))
             ...))))]))

(define-syntax (debug stx)
  (syntax-parse stx
    [(debug #:on)
     (begin (expand-debug? #t) #'(debug? #t))]
    [(debug #:off)
     (begin (expand-debug? #f) #'(debug? #f))]
    [(debug expr ...)
     #'(syntax-parameterize 
        ([conde (... (syntax-rules ()
                       ([_ clauses ...]
                        (debug-conde clauses ...))))])
        (parameterize ([debug? #t])
          expr ...))]))

(define-syntax-rule (conda (g0 g ...) (g1 g^ ...) ...)
  (lambdag@ (a)
    (inc (ifa ((app-goal g0 a) g ...) 
              ((app-goal g1 a) g^ ...) ...))))

(define-syntax ifa
  (syntax-rules ()
    ((_) (mzerog))
    ((_ (e g ...) b ...)
     (let loop ((a-inf e))
       (case-inf a-inf
         (() (ifa b ...))
         ((f) (inc (loop (f))))
         ((a) (bindg* a-inf g ...))
         ((a f) (bindg* a-inf g ...)))))))

(define-syntax-rule (condu (g0 g ...) (g1 g^ ...) ...)
  (lambdag@ (a)
    (inc
     (ifu ((app-goal g0 a) g ...)
          ((app-goal g1 a) g^ ...) ...))))

(define-syntax ifu
  (syntax-rules ()
    ((_) (mzerog))
    ((_ (e g ...) b ...)
     (let loop ((a-inf e))
       (case-inf a-inf
         (() (ifu b ...))
         ((f) (inc (loop (f))))
         ((a) (bindg* a-inf g ...))
         ((a f) (bindg* a g ...)))))))

(define-syntax-rule (project (x ...) g g* ...) 
  (lambdag@-external (a : s)
    (let ((x (walk* x s)) ...)
      ((fresh () g g* ...) a))))

(define onceo (lambda (g) (condu (g))))

(define-syntax (app-goal x)
  (syntax-case x ()
    [(_ g a) #`((wrap-goal g #,(build-srcloc-stx #'g)) a)]))

(define (non-goal-error-msg val)
  (string-append
   "expression evaluated to non-goal where a goal was expected"
   (format "\n  value: ~s" val)))

(define (wrap-goal val src)
  (cond
   [(goal? val) val]
   [(format-source src) => 
    (lambda (loc) (error loc (non-goal-error-msg val)))]
   [else (error (non-goal-error-msg val))]))

;; =============================================================================

(define-generics mk-struct
  ;; recur allows generic traversing of mk-structs.  k should be a
  ;; procedure expecting two arguments, the first thing to process,
  ;; and a list of remaining things to process.
  (recur mk-struct k)

  ;; returns a function that will create a new mk-struct given
  ;; arguments like the arguments to k
  (constructor mk-struct)

  ;; for reification 
  (mk-struct->sexp mk-struct)

  ;; structs also have the option of overriding the occurs-check for
  ;; variables if it's okay to unify a variable to a struct with the
  ;; same variable inside (ex. sets)
  (override-occurs-check? mk-struct)

  #:defaults
  ([pair?
    (define (recur p k)
      (k (car p) (cdr p)))
    (define (constructor p) cons)
    (define (override-occurs-check? p) #f)
    (define (mk-struct->sexp p)
      (pair->sexp p))]
   [vector?
    (define (recur v k)
      (let ([v (vector->list v)])
        (k (car v) (cdr v))))
    (define (constructor v)
      (compose list->vector cons))
    (define (override-occurs-check? v) #f)
    (define (mk-struct->sexp v)
      (vector->sexp v))]))

(define (default-mk-struct? x)
  (or (pair? x) (vector? x)))

(define (same-default-type? x y)
  (or (and (pair? x) (pair? y))
      (and (vector? x) (vector? y))))

(define (pair->sexp p)
  (let ([a (car p)] [d (cdr p)])
    (cons (if (mk-struct? a) (mk-struct->sexp a) a)
          (if (mk-struct? d) (mk-struct->sexp d) d))))

(define (vector->sexp v)
  (vector-map (lambda (t) (if (mk-struct? t) (mk-struct->sexp t) t)) v))

;; == SUBSTITUTIONS ============================================================

;; wraps a substitution
(struct substitution (s)
  #:methods gen:custom-write
  [(define (write-proc . args) (apply write-substitution args))])

;; writes a substitution
(define (write-substitution substitution port mode)
  (define fn (lambda (s) ((parse-mode mode) s port)))
  (define s (substitution-s substitution))
  (fn "#s[")
  (for ([p s])
    (fn " (") (fn (car p)) (fn " . ") (fn (cdr p)) (fn ")"))
  (unless (null? s) (fn " "))
  (fn "]"))

;; the empty association list, abbreviated s
(define empty-s '())

;; extends a substitution with a binding of x to v
(define (ext-s x v s)
  (cons `(,x . ,v) s))

;; checks if x appears in v
(define occurs-check
  (lambda (x v s)
    (let ((v (walk v s)))
      (cond
        ((var? v) (eq? v x))
        ((pair? v) 
         (or (occurs-check x (car v) s)
             (occurs-check x (cdr v) s)))
        (else #f)))))

;; returns the size of a substitution
(define size-s
  (lambda (s)
    (length s)))

;; walk an s
(define (walk v s)
  (cond
   ((and (var? v) (assq v s))
    => (lambda (a) (walk (cdr a) s)))
   (else v)))

;; walks a possibly nested structure
(define (walk* w s)
  (let ((v (walk w s)))
    (cond
     ((mk-struct? v)
      (recur v 
       (lambda (a d) 
         ((constructor v)
          (walk* a s)
          (walk* d s)))))
     (else v))))

;; a function that will safely extend the subsitution with
;; a binding of x to v
(define (update-s-check x v)
  (lambdam@ (a : s c q t)
    (let ([s (substitution-s s)]
          [c (constraint-store-c c)])
      (let ((x (walk x s))
            (v (walk v s)))
        (cond
         ((or (var? x) (var? v))
          (update-s-internal x v s c q t))
         ((equal? x v) a)
         (else #f))))))

;; a function that will insecurely extend the substitution 
;; with a binding of x to v 
(define (update-s-nocheck x v)
  (lambdam@ (a : s c q t)
    (let ([s (substitution-s s)]
          [c (constraint-store-c c)])
      (update-s-internal s c q t))))

(define update-s update-s-check)

;; s and c should be unwrapped
(define (update-s-internal x v s c q t)
  ((run-relevant-constraints (if (var? v) `(,x ,v) `(,x)) c)
   (make-a (substitution (ext-s x v s)) (constraint-store c) q t)))

;; for subsumption checks
(define (replace-s s^)
  (lambdam@ (a : s c q t)
    (make-a (substitution s^) c q t)))

(define (update-s-prefix s^)
  (lambdam@ (a : s c q t)
    (let ([s (substitution-s s)])
      (bindm a
        (let loop ([s^ s^])
          (cond
           [(eq? s s^) identitym]
           [else 
            (composem
             (update-s (caar s^) (cdar s^))
             (loop (cdr s^)))]))))))

;; returns the part of s^ that is a prefix of s
(define (prefix-s s s^)
  (define (loop s^) 
    (cond
     [(eq? s^ s) '()] 
     [else (cons (car s^) (loop (cdr s^)))]))
  (if (null? s) s^ (loop s^)))

;; == CONSTRAINT STORE =========================================================

;; wrapper for a constraint store
(struct constraint-store (c)
  #:guard (lambda args (apply constraint-store-guard args))
  #:methods gen:custom-write
  [(define (write-proc . args) (apply write-constraint-store args))])

(define (constraint-store-guard c name)
  (unless (hash? c) (error 'constraint-store "not a hash ~s\n" c))
  (values c))

;; writes a constraint store
(define (write-constraint-store constraint-store port mode)
  (define fn (lambda (s) ((parse-mode mode) s port)))
  (define c (constraint-store-c constraint-store))
  (fn "#c[")
  (hash-for-each 
   c (lambda (key ocs)(for ([oc ocs]) (fn " ") (fn oc))))
  (unless (null? c) (fn " "))
  (fn "]"))

;; an empty constraint store
(define empty-c (hasheq))

;; extends the constraint store c with oc
(define (ext-c oc c) 
  (hash-update c (oc-rator oc) (lambda (ocs) (cons oc ocs)) '()))

;; checks if oc is in c
(define (memq-c oc c)
  (let ([ocs (filter/rator (oc-rator oc) c)])
    (memq oc ocs)))

;; removes oc from c
(define (remq-c oc c) 
  (hash-update c (oc-rator oc) (lambda (ocs) (remq oc ocs)) '()))

;; removes all ocs in oc* from c
(define (remq*-c oc* c)
  (for/fold ([c c]) ([oc oc*]) (remq-c oc c)))

;; filters the constraint store
(define (filter/rator key c)
  (hash-ref c key '()))

(module+ test
  (check-equal? (filter/rator 'key (hasheq)) '())
  (check-equal? (filter/rator 'key (hasheq 'key '(oc1 oc2))) '(oc1 oc2)))

(define (filter-not/rator sym c)
  (apply append (for/list ([key (remq sym (hash-keys c))]) (hash-ref c key '()))))

(module+ test
  (check-equal? (filter-not/rator 'key1 (hasheq)) '())
  (check-equal? (filter-not/rator 'key1 (hasheq 'key1 '(oc1 oc2))) '())
  (check-equal? (filter-not/rator 'key1 (hasheq 'key2 '(oc2) 'key3 '(oc3))) '(oc2 oc3)))

(define (filter-memq/rator symls c)
  (apply append (for/list ([key symls]) (hash-ref c key '()))))

(module+ test
  (check-equal? (filter-memq/rator '(key) (hasheq)) '())
  (check-equal? (filter-memq/rator '(key) (hasheq 'key '(oc1 oc2))) '(oc1 oc2)))

(define (filter-not-memq/rator symls c)
  (apply append (for/list ([key (hash-keys c)])
                          (cond
                           [(memq key symls) '()]
                           [else (hash-ref c key '())]))))

(module+ test
  (check-equal? (filter-not-memq/rator '(key1) (hasheq)) '())
  (check-equal? (filter-not-memq/rator '(key1) (hasheq 'key1 '(oc1 oc2))) '())
  (check-equal? (filter-not-memq/rator '(key1) (hasheq 'key2 '(oc2) 'key3 '(oc3))) 
                '(oc2 oc3)))

;; adds oc to the constraint store if it contains a non-ground var
(define (update-c oc)
  (lambdam@ (a : s c q t)
    (cond
     ((any/var? (oc-rands oc))
      ((run-constraint-interactions oc) a))
     (else a))))

(define (update-c-nocheck oc)
  (lambdam@ (a : s c q t)
    ((run-constraint-interactions oc) a)))

(define (run-constraint-interactions oc)
  (lambdam@ (a : s c q t)
    (let ([fns (constraint-interactions)])
      (let loop ([fns fns])
        (cond
         [(null? fns) 
          (let ([old-c (constraint-store-c c)])
            (let ([new-store (constraint-store (ext-c oc old-c))])
              (make-a s new-store q t)))]
         [(((cdar fns) oc) a)]
         [else (loop (cdr fns))])))))

;; replaces all ocs with a rator equal to key with ocs^
(define (replace-ocs key ocs^)
  (lambdam@ (a : s c q t)
    (let* ([old-store (constraint-store-c c)]
           [new-c (hash-update old-store key (lambda (ocs) ocs^) '())]
           [new-store (constraint-store new-c)])
      (make-a s new-store q t))))

(define (update-c-prefix c^)
  (lambdam@ (a : s c q t)
    (let ([c (constraint-store-c c)])
      (bindm a
        (for/fold 
         ([fn identitym])
         ([key (hash-keys c^)])
         (let ([ocs (hash-ref c key '())])
           (let loop ([ocs^ (hash-ref c^ key)])
             (cond
              [(eq? ocs ocs^) fn]
              [else
               (composem 
                (update-c-nocheck (car ocs^))
                (loop (cdr ocs^)))]))))))))

(define (c->list c)
  (apply append (hash-values c)))

;; == QUEUE ====================================================================

;; an empty queue 
(define empty-q (lambda () unitg))
(define empty-q? ((curry eq?) empty-q))

(define (ext-q q q^) (lambda () (fresh () (q) (q^))))

;; DFS: first do the continuation that was already in the store, then
;; do the continuation generated by running that goal, then finally do
;; the input continuation
(define (update-q-dfs new-enforce)
  (lambdam@ (a : s c q-old t)
    (let ([q-new
           (lambda ()
             (lambdag@ (a : s c q-new t)
               (((ext-q q-new new-enforce))
                (make-a s c empty-q t))))])
      (make-a s c (ext-q q-old q-new) t))))

;; this interweaves DFS and BFS somehow
(define (update-q-hybrid new-enforce)
  (lambdam@ (a : s c q-old t)
    (let ([q-new
           (lambda ()
             (lambdag@ (a : s c q-new t)
               (((ext-q new-enforce q-new))
                (make-a s c empty-q t))))])
      (make-a s c (ext-q q-old q-new) t))))

;; BFS: first do the continuation that was already in the store,
;; leaving the continuation it generates in the store while the input
;; continuation runs.
(define (update-q-bfs new-enforce)
  (lambdam@ (a : s c q-old t)
    (make-a s c (ext-q q-old new-enforce) t)))

;; == TREE =====================================================================

;; wrapper for the tree
(struct path (t)
  #:methods gen:custom-write
  [(define (write-proc . args) (apply write-path args))])

;; writes a path
(define (write-path path port mode)
  (let ([fn (lambda (s) ((parse-mode mode) s port))])
    (fn "#path[" )
    (unless (null? (path-t path)) (fn " "))
    (for ([br (reverse (path-t path))])
         (fn (format "~s " br)))
    (fn "]")))

;; an empty tree
(define empty-t (path '()))

;; adds a level to the tree with label l if it exists, a gensym otherwise
(define (add-level p l) 
  (cond
   [l (path (cons l (path-t p)))]
   [else (path (cons (gensym 'tr) (path-t p)))]))

;; == PACKAGE ==================================================================

;; a package is a structure containing a substitution and
;; a constraint store
(struct a (s c q t) 
  #:extra-constructor-name make-a
  #:methods gen:custom-write 
  [(define (write-proc . args) (apply write-package args))])

;; when debug?ging is turned on, print out the path as well
(define debug? (make-parameter #f))

;; controls how packages are displayed
(define (write-package a port mode)
  (let ([fn (lambda (s) ((parse-mode mode) s port))])
    (if (debug?)
        (fn (format "#a{ ~s ~a ~a }" (a-t a) (a-s a) (a-c a)))
        (fn (format "#a{ ~a ~a }" (a-s a) (a-c a))))))

;; the empty package
(define empty-a 
  (make-a (substitution empty-s)
          (constraint-store empty-c)
          empty-q
          empty-t))

(define (update-package s/c)
  (composem
   (update-c-prefix (cdr s/c))
   (update-s-prefix (car s/c))))

;; == CONSTRAINTS ==============================================================

;; special lambda for defining constraints
(define-syntax lambdam@
  (syntax-rules (:)
    [(_ (a) e ...)
     (lambda (a) e ...)]
    [(_ (a : s c q t) e ...)
     (lambdam@ (a) 
       (let ([s (a-s a)] 
             [c (a-c a)]
             [q (a-q a)]
             [t (a-t a)])
         e ...))]))

(define-syntax lambdam@-external
  (syntax-rules (:)
    [(_ (a) e ...) 
     (lambdam@ (a) e ...)]
    [(_ (a : s) e ...)
     (lambdam@ (a) 
       (let ([s (substitution-s (a-s a))]) 
         e ...))]
    [(_ (a : s c) e ...)
     (lambdam@ (a) 
       (let ([s (substitution-s (a-s a))] 
             [c (constraint-store-c (a-c a))]) 
         e ...))]))

;; the identity constraint
(define identitym (lambdam@ (a) a))

;; the simplest failing constraint
(define mzerom (lambdam@ (a) #f))

;; applies a constraint to a package
(define (bindm a fm) (fm a))

;; composes two constraints together
(define (composem . fm*)
  (lambdam@ (a)
    (cond
     [(null? fm*) a]
     [((car fm*) a)
      => (apply composem (cdr fm*))]
     [else #f])))

;; constructs a goal from a constraint
(define (goal-construct fm)
  (lambdag@ (a) (fm a)))

;; the representation of a constraint in the constraint store 
;; contains a closure waiting to be evaluated with a new package,
;; a symbolic representation of the constrant's name and it's args
(struct oc (proc rator rands) 
  #:extra-constructor-name make-oc
  #:methods gen:custom-write 
  [(define (write-proc . args) (apply write-oc args))])

;; displays an oc
(define (write-oc oc port mode)
  (define fn (lambda (str) ((parse-mode mode) str port)))
  (fn (format "#oc<~a" (oc-rator oc)))
  (for ([arg (oc-rands oc)])
    (fn (format " ~a" arg)))
  (fn (format ">")))

;; creates an oc given the constraint operation and it's args
(define-syntax (build-oc x)
  (syntax-case x ()
    ((_ op arg ...)
     (with-syntax ([(arg^ ...) (generate-temporaries #'(arg ...))])
       #'(let ((arg^ arg) ...)
           (make-oc (op arg^ ...) 'op `(,arg^ ...)))))))

;; defines an attributed constraint (for attributed variables)
(struct attr-oc oc (type uw?) ;; for "unifies with?"
  #:extra-constructor-name make-attr-oc
  #:methods gen:custom-write
  [(define (write-proc attr-oc port mode)
     (define fn (lambda (str) ((parse-mode mode) str port)))
     (fn (format "#oc<~a ~s" (oc-rator attr-oc) (attr-oc-type attr-oc)))
     (for ([arg (oc-rands attr-oc)])
          (fn (format " ~a" arg)))
     (fn (format ">")))])

;; builds an attributed constraint
(define-syntax build-attr-oc
  (syntax-rules ()
    [(_ op x uw?)
     (let ((x^ x))
       (make-attr-oc (op x^) 'attr `(,x^) 'op uw?))]))

;; gets the attributes of variable x in the constraint store
(define (get-attributes x c)
  (define (x-attr? oc) 
    (eq? (car (oc-rands oc)) x))
  (let ((attrs (filter x-attr? (filter/rator 'attr c))))
    (and (not (null? attrs)) attrs)))

;; defines a lazy-goal oc
(struct lazy-goal-oc oc ()
  #:extra-constructor-name make-lazy-goal-oc)

;; builds a lazy-goal oc
(define-syntax (build-lazy-goal-oc x)
  (syntax-case x ()
    ((_ op arg ...)
     (with-syntax ([(arg^ ...) (generate-temporaries #'(arg ...))])
       #'(let ((arg^ arg) ...)
           (make-lazy-goal-oc (op arg^ ...) 'op `(,arg^ ...)))))))

;; == FIXPOINT =================================================================

;; fixed point algorithm given some variables x* that have changed,
;; and list of constraints c.  will rerun any constraints in c that
;; mention x*
(define (run-constraints c)
  (cond
   [(hash? c)
    (for/fold 
     ([rest identitym])
     ([(key ocs) c])
     (composem 
      (for/fold 
       ([fn identitym])
       ([oc ocs])
       (composem fn (rem/run oc)))
      rest))]
   [(list? c)
    (for/fold 
     ([rest identitym])
     ([oc c])
     (composem rest (rem/run oc)))]
   [else (error 'run-constraints "don't know how to run ~s" c)]))

(define (run-relevant-constraints x* c)
  (for/fold 
   ([rest identitym])
   ([(key ocs) c])
   (composem 
    (for/fold 
     ([fn identitym])
     ([oc ocs]
      #:when (any-relevant/var? (oc-rands oc) x*))
     (composem fn (rem/run oc)))
    rest)))

;; removes a constraint from the constraint store and then 
;; reruns it as if it was just being introduced (will add itself
;; back to the constraint store if it still is waiting on info)
(define (rem/run oc)
  (lambdam@ (a : s c q t)
    (let ([ocs (constraint-store-c c)])
      (cond
       ((memq-c oc ocs)
        ((oc-proc oc)
         (let ([new-c (constraint-store (remq-c oc ocs))])
           (make-a s new-c q t))))
       (else a)))))

;; == PARAMETERS ===============================================================

(define ((extend-parameter param) tag fn)
  (let ((fns (param)))
    (and (not (assq tag fns))
         (param (cons `(,tag . ,fn) fns)))))

;; == ENFORCE CONSTRAINTS ======================================================

;; a list of functions to be run during enforce-constraints
(define enforce-fns (make-parameter '()))
(define extend-enforce-fns (extend-parameter enforce-fns))

;; runs all the enforce-constraint functions in enforce-fns
;; and all the fixpoint-enforce-fns in fixpoint-enforce-fns.. to a fixpoint
(define (enforce-constraints x)
  (fresh ()
    (fixpoint-enforce)
    (for/fold ([f unitg])
              ([fn (map cdr (enforce-fns))])
      (fresh () (fn x) f))))

(define-for-syntax search-strategy (make-parameter 'hybrid))

;; runs the given search strategy on the queue of lazy goals
(define (fixpoint-enforce)
  (lambdag@ (a : s c q t)
    (cond
     [(empty-q? q) a]
     [else 
      ((fresh () (q) (fixpoint-enforce)) 
       (make-a s c empty-q t))])))

;; useful for printing out information during debugging, not exported atm
(define gensym
  (let ([counter 0])
    (lambda ([x 'g])
      (if (number? x)
        (set! counter x)
        (begin0 (string->unreadable-symbol
                 (format "~a~a" x counter))
          (set! counter (add1 counter)))))))

;; convenience macro for defining lazy goals
(define-syntax (define-lazy-goal stx)
  (syntax-parse stx
    [(define-lazy-goal (name args ...) body)
     (with-syntax ([lazy-name 
                    (format-id #'name "lazy-~a" (syntax-e #'name))]
                   [enforce-name 
                    (format-id #'name "enforce-~a" (syntax-e #'name))])
       #`(begin
           (define (name args ...)
             (goal-construct (lazy-name args ...)))
           (define (lazy-name args ...)
             (lambdam@ (a) ;; do not eta
               (let ([enforce-this (lambda () (enforce-name args ...))])
                 (bindm a
                   (#,(case (search-strategy)
                        [(dfs) #'update-q-dfs]
                        [(bfs) #'update-q-bfs]
                        [(hybrid) #'update-q-hybrid]
                        [else (error 'define-lazy-goal 
                                     "unknown search strategy ~s" 
                                     (search-strategy))])
                    enforce-this)))))
           (define (enforce-name args ...) 
             body)))]
    [(define-lazy-goal name (lambda (args ...) body))
     #'(define-lazy-goal (name args ...) body)]))

;; == REIFICATION ==============================================================

;; a list of functions to be run during reification
(define reify-fns        (make-parameter '()))
(define extend-reify-fns (extend-parameter reify-fns))

;; defines whether the constraint store should be printed out
;; with a : inbetween the answer and the constraints on the answer
(define reify-with-colon (make-parameter #t))

;; reifies the constraint store with respect to x
(define (reify x)
  (lambdag@ (a : s c q t)
    (let ([s (substitution-s s)]
          [c (constraint-store-c c)])
      (define v (walk* x s))
      (define r (reify-s v empty-s))
      (define v^ (if (mk-struct? v) (mk-struct->sexp v) v))
      (define answer
        (cond
         ((null? r) v^)
         (else (reify-constraints (walk* v^ r) r c))))
      (choiceg answer empty-f))))

;; reifies a cvar
(define (reify-cvar cvar r) (walk cvar r))

;; reifies the substitution, returning the reified substitution
(define (reify-s v s)
  (let ((v (walk v s)))
    (cond
      ((var? v) 
       `((,v . ,(reify-n v (size-s s))) . ,s))
      ((mk-struct? v) 
       (recur v
        (lambda (a d)
          (reify-s d (reify-s a s)))))
      (else s))))

;; creates a reified symbol
(define (reify-n cvar n)
  (string->symbol (format "~a.~a" (cvar->str cvar) (number->string n))))

;; reifies the constraint store by running all the reification fns
(define (reify-constraints v r ocs)
  (cond
    ((null? ocs) v)
    (else
     (let ((ocs^ (run-reify-fns v r ocs)))
       (cond
        [(null? ocs^) v] 
        [(reify-with-colon) `(,v : . ,(sort-store ocs^))]
        [else `(,v . ,(sort-store ocs^))])))))

;; runs all the reification functions
(define (run-reify-fns v r ocs)
  (for/fold ([ocs^ `()])
            ([fn (map cdr (reify-fns))])
    (append (fn v r ocs) ocs^)))

;; defines a "default" reify function
(define ((default-reify sym cs fn) v r ocs)
  (let ((ocs (filter-memq/rator cs ocs)))
    (let ((rands (filter-not any/var? (walk* (fn (map oc-rands ocs) r) r))))
      (cond
       ((null? rands) `())
       (else `((,sym . ,(sort rands lex<=))))))))

(define ((default-reify-attr sym type fn) v r ocs)
  (let ((ocs (filter (lambda (oc) (eq? (attr-oc-type oc) type))
                     (filter/rator attr-tag ocs))))
    (let ((rands (filter-not any/var? (walk* (fn (map (compose car oc-rands) ocs) r) r))))
      (cond
       ((null? rands) `())
       (else `((,sym . ,(sort rands lex<=))))))))

;; sorts the constraint store by lex<=
(define (sort-store ocs) (sort ocs lex<= #:key car))

;; sorts a list by lex<=
(define (sort-by-lex<= l) (sort l lex<=))

;; for pretty reification
(define lex<=
  (lambda (x y)
    (cond
      ((vector? x) #t)
      ((vector? y) #f)
      ((port? x) #t)
      ((port? y) #f)
      ((procedure? x) #t)
      ((procedure? y) #f)
      ((boolean? x)
       (cond
         ((boolean? y) (or (not x) (eq? x y)))
         (else #t)))
      ((boolean? y) #f)
      ((null? x) #t)
      ((null? y) #f)
      ((char? x)
       (cond
         ((char? y) (char<=? x y))
         (else #t)))
      ((char? y) #f)
      ((number? x)
       (cond
         ((number? y) (<= x y))
         (else #t)))
      ((number? y) #f)
      ((string? x)
       (cond
         ((string? y) (string<=? x y))
         (else #t)))
      ((string? y) #f)
      ((symbol? x)
       (cond
         ((symbol? y)
          (string<=? (symbol->string x)
                     (symbol->string y)))
         (else #t)))
      ((symbol? y) #f)
      ((pair? x)
       (cond
         ((pair? y)
          (cond          
            ((equal? (car x) (car y))
             (lex<= (cdr x) (cdr y)))
            (else (lex<= (car x) (car y)))))))
      ((pair? y) #f)
      (else #t))))

;; == INTEGRATION ==============================================================

;; convenience macro to integrate Scheme and cKanren, 
;; returns n answers to the goals g0 g1 ... where x is fresh
(define-syntax run
  (syntax-rules ()
    ((_ n (x) g0 g1 ...)
     (take n (lambdaf@ ()
               ((fresh (x) g0 g1 ...
                  (enforce-constraints x) 
                  (reify x))
                empty-a))))))

;; RUNS ALL THE THINGS
(define-syntax run*
  (syntax-rules ()
    ((_ (x) g ...) (run #f (x) g ...))))

;; == HELPERS ========================================================

;; returns #t if p contains any variables
(define (any/var? x)
  (cond
   ((mk-struct? x)
    (recur x (lambda (a d) (or (any/var? a) (any/var? d)))))
   (else (var? x))))

;; returns #t if t constains variables in x*
(define (any-relevant/var? t x*)
  (cond
   ((mk-struct? t)
    (recur t (lambda (a d) (or (any-relevant/var? a x*)
                               (any-relevant/var? d x*)))))
   (else (and (var? t) (memq t x*)))))

;; This is a tracing macro, akin to trace-define in Chez Scheme.  Upon
;; entry to the goal, all arguments to the function will be projected
;; in the current substitution and printed out.
(define-syntax trace-define-mk
  (syntax-rules ()
    ((_ (name a* ...) body)
     (trace-define-mk name (lambda (a* ...) body)))
    ((_ name (lambda (a* ...) body))
     (define name
       (lambda (a* ...)
         (fresh ()
           (project (a* ...)
             (begin
               (display (list 'name a* ...))
               (newline)
               succeed))
           body))))))

;; Should be able to think of importing constraint files as using
;; constraints, not as requiring files.  Abstractiiooonnnnn.
(define-syntax-rule (use-constraints file ...) 
  (require file ...))

;; =============================================================================

;; This is a version of application that will catch when users have
;; misplaced goals.

;; If the user is trying to apply a goal to something that is not a
;; package, or trying to apply a goal to zero or many things, they
;; will get an goal-as-fn-exn.  This will fix the stupid "incorrect
;; number of arguments to #<procedure>" errors.

(struct exn:goal-as-fn exn:fail ())
(define (raise-goal-as-fn-exn src)
  (raise
   (exn:goal-as-fn
    (format "~s: goal applied as a procedure" (format-source src))
    (current-continuation-marks))))

;; The only correct application of a goal g is to a package a; i.e. (g a).
(define-for-syntax (valid-app?-pred fn args) 
  (syntax-case args ()
    [(a) #`(or (not (goal? #,fn)) (a? a))]
    [(a* ...) #`(not (goal? #,fn))]))

(define-syntax (#%app-safe x)
  (syntax-case x () 
    [(_ fn arg ...)
     (with-syntax* ([(fn^ arg^ ...) 
                     (generate-temporaries #'(fn arg ...))]
                    [src (build-srcloc-stx #'fn)]
                    [valid-app? (valid-app?-pred #'fn^ #'(arg^ ...))])
       (syntax/loc x
        (let ([fn^ fn])
          (let ([arg^ arg] ...)
            (cond
             [valid-app? (#%app fn^ arg^ ...)]
             [else (raise-goal-as-fn-exn src)])))))]))


;; CHR

(define constraint-interactions
  (make-parameter '()))

(define extend-constraint-interactions
  (extend-parameter constraint-interactions))

(define-syntax (define-constraint-interaction stx)
  (syntax-parse stx 
    [(define-constraint-interaction 
       name
       (constraint-exprs ...)
       (~or (~optional (~seq #:package (a:id : s:id c:id))))
       ...
       clauses ...)
     (define a-name (or (attribute a) (generate-temporaries #'(?a))))
     (define s-name (or (attribute s) (generate-temporaries #'(?s))))
     (define c-name (or (attribute c) (generate-temporaries #'(?c))))
     (with-syntax*
       ([(a s c) (list a-name s-name c-name)]
        [constraint-interaction-expr
         #`(parse-constraint-interaction
            name (constraint-exprs ...) (clauses ...)
            (a s c))])
       #'(extend-constraint-interactions
          'name constraint-interaction-expr))]))

(define-syntax (parse-constraint-interaction stx)
  (syntax-parse stx
    [(parse-constraint-interaction 
      name
      ((rator rands ...) ...)
      ([pred? (constraints ...)] ...)
      (a s c))
     (with-syntax 
       ([(arg ...) (generate-temporaries #'(rator ...))]
        [bad-pattern-error 
         #'(error 'name "bad pattern ~s" '((rator rands ...) ...))])
       #`(let ()
           (define (run-all . arg*)
             (lambdam@ (a : ?s ?c ?q ?t)
               (let ([s (substitution-s ?s)]
                     [c (constraint-store-c ?c)])
                 (match (map oc-rands arg*)
                   [`((rands ...) ...)
                    (cond
                     [pred? 
                      (let ([new-c (remq*-c arg* c)])
                        (let ([new-a (make-a ?s (constraint-store new-c) ?q ?t)])
                          ((composem constraints ...) new-a)))]
                     ...
                     [else #f])]
                   [_ bad-pattern-error]))))
           (define (name oc)
             (let ([this-rator (oc-rator oc)])
               (lambdam@-external (a : s c)
                 (generate-cond run-all (a s c) oc this-rator 
                                () ((rator rands ...) ...)))))
           name))]))

(define-syntax (generate-cond stx)
  (syntax-parse stx 
    [(generate-cond run-all (a s c) oc this-rator (pattern ...) ()) #'#f]
    [(generate-cond 
      run-all (a s c) oc this-rator
      ((rator-pre rand-pre) ...)
      ((rator rand ...) (rator-post rand-post) ...))
     (with-syntax
      ([(pre ...) (generate-temporaries #'(rator-pre ...))]
       [(post ...) (generate-temporaries #'(rand-post ...))])
      (with-syntax*
       ([(pre-ocs ...)  #'((filter/rator 'rator-pre c) ...)]
        [(post-ocs ...) #'((filter/rator 'rator-post c) ...)]
        [pattern-applies? #'(eq? 'rator this-rator)]
        [run-rule
         #'(bindm a
             (for*/fold
              ([fn mzerom])
              ([pre    pre-ocs] ...
               [this (list oc)]
               [post  post-ocs] ...)
              (lambdam@-external (a : s c)
                (cond
                 [((run-all pre ... this post ...) a)]
                 [else (fn a)]))))]
        [rest-formatted 
         #'(generate-cond 
            run-all (a s c) oc this-rator
            ((rator-pre rand-pre) ... (rator rand ...))
            ((rator-post rand-post) ...))])
       #'(cond
          [(and pattern-applies? run-rule)]
          [else rest-formatted])))]))


