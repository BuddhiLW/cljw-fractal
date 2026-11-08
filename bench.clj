;; Run from the repository root: cljw bench.clj
;; Render timing excludes framebuffer transfer, checksum and PPM encoding.
;; CLJW_FRACTAL_CI=1 selects small correctness cases for the e2e gate.
(ns fractal.bench (:require [clojure.java.io :as io]))

(def root (str (or (System/getenv "FRACTAL_DIR")
                   (not-empty (.getParent (io/file *file*)))
                   ".") "/"))
(def views
  (if (= "1" (System/getenv "CLJW_FRACTAL_CI"))
    [{:name "full" :cx -0.5 :cy 0.0 :scale (/ 3.5 32) :w 32 :h 32 :iter 64}
     {:name "seahorse" :cx -0.743643887037151 :cy 0.13182590420533 :scale 1.0e-6 :w 16 :h 16 :iter 160}
     {:name "odd-tail" :cx -0.5 :cy 0.0 :scale 0.1 :w 31 :h 29 :iter 80}]
    [{:name "full" :cx -0.5 :cy 0.0 :scale (/ 3.5 512) :w 512 :h 512 :iter 256}
     {:name "seahorse" :cx -0.743643887037151 :cy 0.13182590420533 :scale 1.0e-6 :w 128 :h 128 :iter 2000}
     {:name "odd-tail" :cx -0.5 :cy 0.0 :scale 0.1 :w 31 :h 29 :iter 80}]))

(defn checksum [pixels]
  (reduce (fn [acc b] (mod (+ (* acc 31) (bit-and 255 b)) 2147483647)) 1 pixels))

(defn ppm! [pixels w h]
  ;; P3 is portable text PPM, avoiding host-specific binary stream methods.
  (with-open [out (io/writer "/tmp/cljw-fractal-out.ppm")]
    (.write out (str "P3\n" w " " h "\n255\n"))
    (dotimes [i (* w h)]
      (.write out (str (bit-and 255 (aget pixels (* i 4))) " "
                       (bit-and 255 (aget pixels (+ (* i 4) 1))) " "
                       (bit-and 255 (aget pixels (+ (* i 4) 2))) "\n")))))

(def references (atom {}))
(defn run-frame! [module engine export view]
  (let [{:keys [name cx cy scale w h iter]} view
        _ (assert (= 0 (.set_view module cx cy scale)))
        start (System/nanoTime)
        iterations (wasm/call module export w h iter)
        ms (/ (- (System/nanoTime) start) 1.0e6)
        pixels (wasm/mem-read-array module :u8 (.fb_ptr module) (* w h 4))
        sum (checksum pixels)
        result [iterations sum]]
    (println engine export name "ms" ms "Miter/s" (/ iterations (* ms 1000.0))
             "iterations" iterations "checksum" sum)
    (if-let [reference (get @references name)]
      (assert (= reference result) (str "parity mismatch: " engine " " export " " name))
      (swap! references assoc name result))
    (when (and (= engine :interp) (= export "render") (= name "full"))
      (ppm! pixels w h))))

(doseq [engine [:jit :interp]]
  (let [module (wasm/load (str root "kernel.wasm") {:engine engine :fuel 0})]
    (let [exports (wasm/exports module)]
      (println "exports" engine exports)
      (doseq [export ["render" "render_simd"]]
        (let [signature (first (filter #(= export (:name %)) exports))]
          (assert (= [:i32 :i32 :i32] (:params signature)))
          (assert (= [:i64] (:results signature))))))
    (assert (= 1048576 (.fb_cap module)))
    (doseq [export ["render" "render_simd"] view views]
      (run-frame! module engine export view))))
(println "PASS scalar artifact: strict engine and vector-source parity")

;; SIMD instructions are JIT-only in zwasm. Keep this artifact separate so the
;; scalar module remains usable by the interpreter and browsers without SIMD.
(let [module (wasm/load (str root "kernel_simd.wasm") {:engine :jit :fuel 0})]
  (doseq [export ["render" "render_simd"] view views]
    (run-frame! module :jit-simd export view))
  (println "PASS simd128 JIT strict parity"))
(println "Wrote /tmp/cljw-fractal-out.ppm")

(defn same-bytes? [a b]
  (and (= (alength a) (alength b))
       (loop [i 0]
         (cond
           (= i (alength a)) true
           (not= (aget a i) (aget b i)) false
           :else (recur (inc i))))))

(defn orbit-bytes [path]
  (let [size (.length (io/file path))
        bytes (byte-array size)]
    (with-open [in (io/input-stream (io/file path))]
      (dotimes [i size]
        (let [b (.read in)]
          (assert (not (neg? b)) "orbit fixture shrank under read")
          (aset-byte bytes i (unchecked-byte b)))))
    bytes))

(def shallow-orbit
  (let [zs (double-array (* 257 2))]
    (dotimes [m 256]
      (let [zr (aget zs (* m 2))
            zi (aget zs (inc (* m 2)))]
        (aset-double zs (* (inc m) 2) (- (* zr zr) (* zi zi) 0.5))
        (aset-double zs (inc (* (inc m) 2)) (* 2.0 zr zi))))
    zs))

(def deep-orbit
  (let [start (System/nanoTime)
        bytes (orbit-bytes (str root "fixtures/seahorse-1e30.orbit"))]
    (assert (and (zero? (mod (alength bytes) 16)) (>= (alength bytes) 32)))
    (println "orbit fixture bytes" (alength bytes) "read-ms" (/ (- (System/nanoTime) start) 1.0e6))
    bytes))

(def perturb-views
  (let [ci? (= "1" (System/getenv "CLJW_FRACTAL_CI"))
        w (if ci? 32 256)
        h (if ci? 24 192)]
    [{:name "perturb-shallow" :orbit shallow-orbit :dtype :f64 :entries 257
      :dcx 0.0 :dcy 0.0 :scale 0.01 :w w :h h :iter 256}
     {:name "perturb-seahorse-1e30" :orbit deep-orbit :dtype :i8 :entries (/ (alength deep-orbit) 16)
      :dcx 0.0 :dcy 0.0 :scale 1.0e-30 :w w :h h :iter 5000}
     {:name "perturb-rebase-odd" :orbit shallow-orbit :dtype :f64 :entries 3
      :dcx 0.1 :dcy -0.0125 :scale 0.02 :w 31 :h 29 :iter 256}]))

(def perturb-references (atom {}))
(defn run-perturb! [module engine view]
  (let [{:keys [name orbit dtype entries dcx dcy scale w h iter]} view
        start (System/nanoTime)
        written (wasm/mem-write! module dtype (.orbit_ptr module) orbit)
        upload-ms (/ (- (System/nanoTime) start) 1.0e6)]
    (assert (= (alength orbit) written))
    (assert (= 0 (.set_ref module entries)))
    (assert (= 0 (.set_delta module dcx dcy scale)))
    (let [start (System/nanoTime)
          iterations (.render_perturb module w h iter)
          ms (/ (- (System/nanoTime) start) 1.0e6)
          pixels (wasm/mem-read-array module :u8 (.fb_ptr module) (* w h 4))
          sum (checksum pixels)]
      (assert (pos? iterations))
      (println engine "render_perturb" name "size" (str w "x" h) "ms" ms
               "Miter/s" (/ iterations (* ms 1000.0)) "upload-ms" upload-ms
               "iterations" iterations "checksum" sum)
      (if-let [reference (get @perturb-references name)]
        (do
          (assert (= iterations (:iterations reference)) (str "iteration mismatch: " engine " " name))
          (assert (same-bytes? pixels (:pixels reference)) (str "byte mismatch: " engine " " name)))
        (swap! perturb-references assoc name {:iterations iterations :pixels pixels})))))

(doseq [[artifact engine label] [["kernel.wasm" :jit :jit]
                                 ["kernel.wasm" :interp :interp]
                                 ["kernel_simd.wasm" :jit :jit-simd]]]
  (let [module (wasm/load (str root artifact) {:engine engine :fuel 0})
        exports (wasm/exports module)]
    (assert (= 65536 (.orbit_cap module)))
    (doseq [[name params results] [["orbit_ptr" [] [:i32]]
                                    ["orbit_cap" [] [:i32]]
                                    ["set_ref" [:i32] [:i32]]
                                    ["set_delta" [:f64 :f64 :f64] [:i32]]
                                    ["render_perturb" [:i32 :i32 :i32] [:i64]]]]
      (let [signature (first (filter #(= name (:name %)) exports))]
        (assert (= params (:params signature)))
        (assert (= results (:results signature)))))
    (doseq [view perturb-views]
      (run-perturb! module label view))))
(println "PASS perturbation: byte-identical scalar JIT/interp and simd128 JIT")
